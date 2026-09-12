import Foundation

public struct H264SpsSummary: Sendable, Equatable {
    public let profileIdc: UInt8
    public let constraintFlags: UInt8
    public let levelIdc: UInt8
    public let numRefFrames: UInt32
    public let picOrderCntType: UInt32
    public let hasVui: Bool
    public let maxNumReorderFrames: UInt32?
    public let maxDecFrameBuffering: UInt32?
}

/// SPS 改寫：注入 VUI `bitstream_restriction`，讓手機的 `VideoDecoder` 不囤幀
/// （spec 第 1 節：未改寫 p50 172 ms、改寫後 4 ms）。
///
/// 只適用於本專案 `-bf 0`、無重排序的串流。演算法移植自 spike `relay.py` 的 `rewrite_sps`：
/// 走完 7.3.2.1.1 到 frame cropping，記住到此為止的位元；VUI 存在時再走 E.1.1 到
/// `bitstream_restriction_flag` 之前；然後丟掉舊 restriction 與 trailing bits，接上固定的
/// restriction 重新結尾。除了 restriction 那一段，其他位元逐一保留。
public enum H264SpsRewriter {
    static let maxNumReorderFrames: UInt32 = 0
    private static let log2MaxMvLength: UInt32 = 16
    private static let highProfiles: Set<UInt32> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
    private static let maxPocCycle: UInt32 = 255
    private static let maxHrdCount: UInt32 = 32
    private static let vuiOptionalFlagCount = 8   // VUI 不存在時補的零：五個 present flag、兩個 HRD flag、pic_struct

    private struct Header {
        let profileIdc: UInt8
        let constraintFlags: UInt8
        let levelIdc: UInt8
        let numRefFrames: UInt32
        let picOrderCntType: UInt32
    }

    private struct Parsed {
        let nalHeader: UInt8
        let header: Header
        let hasVui: Bool
        let prefix: [Bool]                  // 到 restriction 之前的所有位元（含 vui_present=1）
        let existingRestriction: [UInt32]?  // [mv_over_boundaries, bytes_denom, bits_denom, mv_h, mv_v, reorder, buffering]
    }

    public static func rewrite(_ sps: Data) throws -> Data {
        let parsed = try parse(sps)
        let restriction: [Bool] = [true, true]
            + H264Rbsp.ueBits(0) + H264Rbsp.ueBits(0)
            + H264Rbsp.ueBits(log2MaxMvLength) + H264Rbsp.ueBits(log2MaxMvLength)
            + H264Rbsp.ueBits(maxNumReorderFrames)
            + H264Rbsp.ueBits(max(1, parsed.header.numRefFrames))
        return Data([parsed.nalHeader]) + H264Rbsp.escape(H264Rbsp.finishRbsp(parsed.prefix + restriction))
    }

    public static func rewriteOrNil(_ sps: Data) -> Data? {
        try? rewrite(sps)
    }

    public static func summary(of sps: Data) throws -> H264SpsSummary {
        let parsed = try parse(sps)
        return H264SpsSummary(
            profileIdc: parsed.header.profileIdc, constraintFlags: parsed.header.constraintFlags,
            levelIdc: parsed.header.levelIdc, numRefFrames: parsed.header.numRefFrames,
            picOrderCntType: parsed.header.picOrderCntType, hasVui: parsed.hasVui,
            maxNumReorderFrames: parsed.existingRestriction?[5],
            maxDecFrameBuffering: parsed.existingRestriction?[6])
    }

    // MARK: - 解析

    private static func parse(_ sps: Data) throws -> Parsed {
        guard let type = H264Nal.rawType(of: sps), type == H264NalType.sps.rawValue else {
            throw H264SpsError.notSps
        }
        let payload = try H264Rbsp.unescape(sps.dropFirst())
        var r = H264BitReader(bits: H264Rbsp.bits(of: payload))
        let header = try readSeqParameterSet(&r)
        var prefix = Array(r.bits[0..<r.position]) + [true]
        let hasVui = try r.flag()
        var existing: [UInt32]?
        if hasVui {
            let start = r.position
            try skipVuiPrefix(&r)
            prefix += r.bits[start..<r.position]
            if try r.flag() {  // bitstream_restriction_flag
                let overBoundaries = try r.u(1)
                var values = [overBoundaries]
                for _ in 0..<6 {
                    let value = try r.ue()
                    values.append(value)
                }
                existing = values
            }
        } else {
            prefix += Array(repeating: false, count: vuiOptionalFlagCount)
        }
        let trailing = r.bits[r.position...]
        guard trailing.first == true, !trailing.dropFirst().contains(true) else {
            throw H264SpsError.invalidTrailingBits
        }
        return Parsed(nalHeader: sps[sps.startIndex], header: header, hasVui: hasVui,
                      prefix: prefix, existingRestriction: existing)
    }

    /// 7.3.2.1.1 從 profile_idc 走到 frame cropping。
    private static func readSeqParameterSet(_ r: inout H264BitReader) throws -> Header {
        let profile = try r.u(8)
        let constraints = try r.u(8)
        let level = try r.u(8)
        _ = try r.ue()  // seq_parameter_set_id
        if highProfiles.contains(profile) {
            let chroma = try r.ue()
            guard chroma <= 3 else { throw H264SpsError.invalidField("chroma_format_idc") }
            if chroma == 3 { _ = try r.flag() }  // separate_colour_plane_flag
            _ = try r.ue()   // bit_depth_luma_minus8
            _ = try r.ue()   // bit_depth_chroma_minus8
            _ = try r.flag() // qpprime_y_zero_transform_bypass_flag
            if try r.flag() {  // seq_scaling_matrix_present_flag
                let lists = chroma == 3 ? 12 : 8
                for i in 0..<lists {
                    if try r.flag() { try skipScalingList(&r, size: i < 6 ? 16 : 64) }
                }
            }
        }
        _ = try r.ue()  // log2_max_frame_num_minus4
        let poc = try r.ue()
        switch poc {
        case 0:
            _ = try r.ue()  // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            _ = try r.flag()
            _ = try r.se()
            _ = try r.se()
            let cycle = try r.ue()
            guard cycle <= maxPocCycle else { throw H264SpsError.invalidField("num_ref_frames_in_pic_order_cnt_cycle") }
            for _ in 0..<cycle { _ = try r.se() }
        case 2:
            break
        default:
            throw H264SpsError.invalidField("pic_order_cnt_type")
        }
        let refs = try r.ue()
        _ = try r.flag()  // gaps_in_frame_num_value_allowed_flag
        _ = try r.ue()    // pic_width_in_mbs_minus1
        _ = try r.ue()    // pic_height_in_map_units_minus1
        let frameMbsOnly = try r.flag()
        if !frameMbsOnly { _ = try r.flag() }  // mb_adaptive_frame_field_flag
        _ = try r.flag()  // direct_8x8_inference_flag
        if try r.flag() {  // frame_cropping_flag
            for _ in 0..<4 { _ = try r.ue() }
        }
        return Header(profileIdc: UInt8(profile), constraintFlags: UInt8(constraints), levelIdc: UInt8(level),
                      numRefFrames: refs, picOrderCntType: poc)
    }

    private static func skipScalingList(_ r: inout H264BitReader, size: Int) throws {
        var last: Int32 = 8
        var next: Int32 = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = try r.se()
                guard (-128...127).contains(delta) else {
                    throw H264SpsError.invalidField("delta_scale")
                }
                next = (last + delta + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    /// E.1.1 走到 bitstream_restriction_flag 之前。
    private static func skipVuiPrefix(_ r: inout H264BitReader) throws {
        if try r.flag() {  // aspect_ratio_info_present_flag
            if try r.u(8) == 255 { _ = try r.u(32) }  // Extended_SAR：sar_width、sar_height
        }
        if try r.flag() { _ = try r.flag() }  // overscan_info_present → overscan_appropriate
        if try r.flag() {  // video_signal_type_present_flag
            _ = try r.u(4)  // video_format(3) + video_full_range_flag(1)
            if try r.flag() { _ = try r.u(24) }  // colour_primaries、transfer、matrix
        }
        if try r.flag() {  // chroma_loc_info_present_flag
            _ = try r.ue()
            _ = try r.ue()
        }
        if try r.flag() {  // timing_info_present_flag
            _ = try r.u(32)
            _ = try r.u(32)
            _ = try r.flag()
        }
        let nalHrd = try r.flag()
        if nalHrd { try skipHrd(&r) }
        let vclHrd = try r.flag()
        if vclHrd { try skipHrd(&r) }
        if nalHrd || vclHrd { _ = try r.flag() }  // low_delay_hrd_flag
        _ = try r.flag()  // pic_struct_present_flag
    }

    private static func skipHrd(_ r: inout H264BitReader) throws {
        let count = try r.ue() + 1
        guard count <= maxHrdCount else { throw H264SpsError.invalidField("cpb_cnt_minus1") }
        _ = try r.u(8)  // bit_rate_scale(4) + cpb_size_scale(4)
        for _ in 0..<count {
            _ = try r.ue()
            _ = try r.ue()
            _ = try r.flag()
        }
        _ = try r.u(20)  // 四個 length 欄位各 5 bits
    }
}

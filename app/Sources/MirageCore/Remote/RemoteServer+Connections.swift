import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// `GET /` 與被拒的升級請求：回一則 HTTP 回應後關閉。
enum RemoteHTTPConnection {
    typealias Channel = NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>
    private static let htmlType = "text/html; charset=utf-8"
    private static let textType = "text/plain; charset=utf-8"

    static func run(_ channel: Channel, core: RemoteServerCore) async throws {
        let channelID = ObjectIdentifier(channel.channel)
        try await channel.executeThenClose { inbound, outbound in
            // 帶 Upgrade 標頭但被拒絕時，NIO 不會重送 head。先消耗保存的拒絕決定。
            if let rejection = core.takePendingRejection(channelID: channelID) {
                try await outbound.write(contentsOf: responseParts(for: rejection, viewerPage: core.configuration.viewerPage))
                return
            }
            for try await part in inbound {
                guard case .head(let head) = part else { continue }
                let route = core.route(method: head.method.rawValue, uri: head.uri)
                core.recordHTTP(route)
                try await outbound.write(contentsOf: responseParts(for: route, viewerPage: core.configuration.viewerPage))
                return
            }
        }
    }

    /// 兩種 HTTP 路徑使用相同 part 型別，由 RemoteHTTPResponsePartHandler 轉給 encoder。
    /// 不快取配對頁；完整寫 head/body/end 後才離開 executeThenClose scope。
    private static func responseParts(for route: RemoteRoute, viewerPage: Data)
        -> [HTTPPart<HTTPResponseHead, ByteBuffer>]
    {
        let response = response(for: route, viewerPage: viewerPage)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: String(response.body.count))
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Connection", value: "close")
        return [
            .head(HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)),
            .body(ByteBuffer(bytes: response.body)),
            .end(nil),
        ]
    }

    static func response(for route: RemoteRoute, viewerPage: Data)
        -> (status: HTTPResponseStatus, body: Data, contentType: String)
    {
        switch route {
        case .viewer:
            return (.ok, viewerPage, htmlType)
        case .forbidden:
            return (.forbidden, Data("forbidden\n".utf8), textType)
        case .busy:
            return (.conflict, Data("a viewer is already connected\n".utf8), textType)
        case .videoRequired:
            return (.conflict, Data("connect /ws/video before /ws/input\n".utf8), textType)
        case .notFound:
            return (.notFound, Data("not found\n".utf8), textType)
        case .methodNotAllowed:
            return (.methodNotAllowed, Data("method not allowed\n".utf8), textType)
        case .upgradeVideo, .upgradeInput:
            return (.upgradeRequired, Data("websocket upgrade required\n".utf8), textType)
        }
    }
}

/// `/ws/video`：送影像並接受補 keyframe 請求（另回 pong、收 close）。寫出迴圈由 `RemoteServerCore` 的 wakeup 驅動。
enum RemoteVideoConnection {
    static func run(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        core: RemoteServerCore
    ) async throws {
        let channelID = ObjectIdentifier(channel.channel)
        let wakeups = core.attachVideoWakeups(channelID: channelID)
        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await frame in inbound {
                        switch frame.opcode {
                        case .connectionClose:
                            try await outbound.write(WebSocketFrame(
                                fin: true,
                                opcode: .connectionClose,
                                data: frame.unmaskedData
                            ))
                            return
                        case .text:
                            // 固定短指令，不接受分片或其他 viewer 輸入。
                            let data = frame.unmaskedData
                            if frame.fin && data.readableBytes == 8 &&
                                data.getString(at: data.readerIndex, length: 8) == "keyframe" {
                                core.requestVideoKeyframe(channelID: channelID)
                            }
                        case .ping:
                            try await outbound.write(WebSocketFrame(
                                fin: true,
                                opcode: .pong,
                                data: frame.unmaskedData
                            ))
                        default:
                            break
                        }
                    }
                }
                group.addTask {
                    // wakeup 只合併通知，實際資料與 GOP 丟棄規則仍在 core 的佇列。
                    // writer 等待可寫期間，producer 仍能 offer 並觸發背壓丟幀。
                    for await _ in wakeups {
                        while let entry = core.popVideoEntry(channelID: channelID) {
                            let message = RemoteVideoMessage(
                                sentAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                sequence: entry.sequence,
                                isKeyframe: entry.isKeyframe,
                                accessUnit: entry.accessUnit
                            )
                            let frame = WebSocketFrame(
                                fin: true,
                                opcode: .binary,
                                data: ByteBuffer(bytes: message.encoded())
                            )
                            try await outbound.write(frame)
                            core.recordSent()
                        }
                    }
                }
                // 即使 next 拋錯也取消另一個迴圈，讓 executeThenClose 能關閉 channel。
                defer { group.cancelAll() }
                try await group.next()
            }
        }
    }
}

/// `/ws/input`：文字訊息交給 core，ping 原封 echo。
enum RemoteInputConnection {
    static func run(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        core: RemoteServerCore
    ) async throws {
        let channelID = ObjectIdentifier(channel.channel)
        try await channel.executeThenClose { inbound, outbound in
            var assembler = RemoteInputTextAssembler()
            for try await frame in inbound {
                switch frame.opcode {
                case .connectionClose:
                    try await outbound.write(WebSocketFrame(
                        fin: true,
                        opcode: .connectionClose,
                        data: frame.unmaskedData
                    ))
                    return
                case .ping:
                    try await outbound.write(WebSocketFrame(
                        fin: true,
                        opcode: .pong,
                        data: frame.unmaskedData
                    ))
                case .text, .continuation, .binary:
                    guard let text = try assembler.append(frame) else { continue }
                    if let reply = core.handleInputText(text, channelID: channelID) {
                        try await outbound.write(WebSocketFrame(
                            fin: true,
                            opcode: .text,
                            data: ByteBuffer(string: reply)
                        ))
                    }
                default:
                    break
                }
            }
        }
    }
}

/// NIO 交付的是 frame，不保證一個 frame 就是一則完整 JSON。
/// 先合併 text＋continuation 才交給 decoder，避免半則 down 被提前送進 allocator。
/// 控制 frame 由上層處理，不打斷正在接收的訊息。
private struct RemoteInputTextAssembler {
    private static let maximumBytes = 1 << 16
    // UTF-8 僅於最後一片解碼，字元可以跨 frame。
    private var bytes = Data()
    private var fragmented = false

    enum MessageError: Error {
        case unexpectedContinuation
        case overlappingMessage
        case unsupportedBinary
        case tooLarge
        case invalidUTF8
    }

    mutating func append(_ frame: WebSocketFrame) throws -> String? {
        switch frame.opcode {
        case .text:
            guard !fragmented else { throw MessageError.overlappingMessage }
        case .continuation:
            guard fragmented else { throw MessageError.unexpectedContinuation }
        case .binary:
            throw MessageError.unsupportedBinary
        default:
            return nil
        }

        let payload = frame.unmaskedData
        guard payload.readableBytes <= Self.maximumBytes - bytes.count else {
            throw MessageError.tooLarge
        }
        bytes.append(contentsOf: payload.readableBytesView)
        fragmented = !frame.fin
        guard frame.fin else { return nil }
        defer { bytes.removeAll(keepingCapacity: true) }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw MessageError.invalidUTF8
        }
        return text
    }
}

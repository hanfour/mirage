import Foundation

public enum SetupSpace {
    // 3.2 follows fetch.ensure_space's measured 3.12x emulator expansion, rounded up for margin.
    public static let extractionMultiplier = 3.2
    // Reserve 2 GiB for first-boot userdata, per first-run setup design section 4.6.
    public static let userDataReserveBytes: Int64 = 2 * 1024 * 1024 * 1024

    public static func required(for missing: [SetupMissingItem]) -> Int64 {
        let zippedBytes = missing.reduce(Int64(0)) { $0 + $1.size }
        return Int64((Double(zippedBytes) * extractionMultiplier).rounded(.up)) + userDataReserveBytes
    }

    public static func required(forPackageSize size: Int64) -> Int64 {
        Int64((Double(size) * extractionMultiplier).rounded(.up))
    }
}

public enum SetupGate {
    public static func canStart(agreed: Bool, required: Int64, available: Int64) -> Bool {
        agreed && available >= required
    }
}

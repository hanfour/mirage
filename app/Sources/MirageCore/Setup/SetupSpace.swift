import Foundation

public enum SetupSpace {
    // 3.2 follows fetch.ensure_space's measured 3.12x emulator expansion, rounded up for margin.
    public static let extractionMultiplier = 3.2
    // Emulator reports 9830.40 MB for an 8192 MiB partition: 9830.40 / 8192 = 1.2.
    public static let dataPartitionSpaceMultiplier = 1.2
    public static let dataPartitionSizeKey = "disk.dataPartition.size"
    public static let defaultDataPartitionBytes: Int64 = 8 * 1024 * 1024 * 1024
    public static let minimumTestDataPartitionBytes: Int64 = 1024 * 1024 * 1024

    public static func resolvedDataPartitionBytes(
        in configBase: [String: String]
    ) -> (bytes: Int64, usedDefault: Bool) {
        if let raw = configBase[dataPartitionSizeKey], let bytes = Int64(raw), bytes > 0 {
            return (bytes, false)
        }
        return (defaultDataPartitionBytes, true)
    }

    public static func required(
        for missing: [SetupMissingItem],
        dataPartitionBytes: Int64 = defaultDataPartitionBytes
    ) -> Int64 {
        let zippedBytes = missing.reduce(Int64(0)) { $0 + $1.size }
        let extractionBytes = Int64((Double(zippedBytes) * extractionMultiplier).rounded(.up))
        let needsAVD = missing.contains {
            if case .avd = $0.kind { return true }
            return false
        }
        let partitionBytes = needsAVD
            ? Int64((Double(dataPartitionBytes) * dataPartitionSpaceMultiplier).rounded(.up))
            : 0
        return extractionBytes + partitionBytes
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

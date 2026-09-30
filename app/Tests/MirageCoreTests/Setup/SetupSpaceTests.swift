import Foundation
import Testing
@testable import MirageCore

@Suite("SetupSpace and SetupGate")
struct SetupSpaceTests {
    @Test func fullInstallUsesZipTotalTimesMultiplierPlusPartitionHeadroom() throws {
        let spec = try SdkSpec.bundled().get()
        let missingPackages = spec.packages.filter {
            $0.path == "emulator" || $0.path == "platform-tools" || $0.manifestKey == "sysimg_playstore"
        }
        let zipped = missingPackages.reduce(Int64(0)) { $0 + $1.size }
        let missing = missingPackages.map {
            SetupMissingItem(kind: .package(installPath: $0.installPath), name: $0.path, size: $0.size)
        } + [SetupMissingItem(kind: .avd(name: "mirage-game"), name: "mirage-game AVD", size: 0)]
        let partition = SetupSpace.resolvedDataPartitionBytes(in: spec.configBase)
        #expect(!partition.usedDefault)
        let expected = Int64((Double(zipped) * SetupSpace.extractionMultiplier).rounded(.up))
            + Int64((Double(partition.bytes) * SetupSpace.dataPartitionSpaceMultiplier).rounded(.up))
        #expect(SetupSpace.required(for: missing, dataPartitionBytes: partition.bytes) == expected)
    }

    @Test func onlyMissingPackageDoesNotReserveAnExistingAvdPartition() {
        let item = SetupMissingItem(kind: .package(installPath: "emulator"),
                                    name: "Android Emulator", size: 394_555_844)
        #expect(SetupSpace.required(for: [item], dataPartitionBytes: SetupSpace.defaultDataPartitionBytes) ==
                Int64((Double(item.size) * SetupSpace.extractionMultiplier).rounded(.up)))
        #expect(SetupSpace.required(forPackageSize: item.size) ==
                Int64((Double(item.size) * SetupSpace.extractionMultiplier).rounded(.up)))
    }

    @Test func missingPartitionFieldFallsBackToEightGiB() {
        let partition = SetupSpace.resolvedDataPartitionBytes(in: [:])
        #expect(partition.usedDefault)
        #expect(partition.bytes == SetupSpace.defaultDataPartitionBytes)

        let missingAVD = SetupMissingItem(kind: .avd(name: "mirage-game"), name: "AVD", size: 0)
        #expect(SetupSpace.required(for: [missingAVD], dataPartitionBytes: partition.bytes)
                == Int64((Double(SetupSpace.defaultDataPartitionBytes)
                          * SetupSpace.dataPartitionSpaceMultiplier).rounded(.up)))
    }

    @Test func gateRequiresAgreementAndEnoughSpace() {
        #expect(!SetupGate.canStart(agreed: false, required: 10, available: 20))
        #expect(!SetupGate.canStart(agreed: true, required: 20, available: 10))
        #expect(SetupGate.canStart(agreed: true, required: 10, available: 10))
    }
}

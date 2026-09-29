import Foundation
import Testing
@testable import MirageCore

@Suite("SetupSpace and SetupGate")
struct SetupSpaceTests {
    @Test func fullInstallUsesZipTotalTimesMultiplierPlusUserdataReserve() throws {
        let spec = try SdkSpec.bundled().get()
        let missingPackages = spec.packages.filter {
            $0.path == "emulator" || $0.path == "platform-tools" || $0.manifestKey == "sysimg_playstore"
        }
        let zipped = missingPackages.reduce(Int64(0)) { $0 + $1.size }
        let missing = missingPackages.map {
            SetupMissingItem(kind: .package(installPath: $0.installPath), name: $0.path, size: $0.size)
        } + [SetupMissingItem(kind: .avd(name: "mirage-game"), name: "mirage-game AVD", size: 0)]
        let expected = Int64((Double(zipped) * 3.2).rounded(.up)) + SetupSpace.userDataReserveBytes
        #expect(SetupSpace.required(for: missing) == expected)
        #expect(SetupSpace.required(for: missing) > 9_000_000_000)
        #expect(SetupSpace.required(for: missing) < 10_000_000_000)
    }

    @Test func partialInstallCountsOnlyMissingPackageArchives() {
        let item = SetupMissingItem(kind: .package(installPath: "emulator"),
                                    name: "Android Emulator", size: 394_555_844)
        #expect(SetupSpace.required(for: [item]) ==
                Int64((Double(item.size) * 3.2).rounded(.up)) + SetupSpace.userDataReserveBytes)
        #expect(SetupSpace.required(forPackageSize: item.size) ==
                Int64((Double(item.size) * 3.2).rounded(.up)))
    }

    @Test func gateRequiresAgreementAndEnoughSpace() {
        #expect(!SetupGate.canStart(agreed: false, required: 10, available: 20))
        #expect(!SetupGate.canStart(agreed: true, required: 20, available: 10))
        #expect(SetupGate.canStart(agreed: true, required: 10, available: 10))
    }
}

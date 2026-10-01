import Testing
@testable import MirageCore

@Suite struct DisplayTransportSelectorTests {
    @Test func versionAndEnvironmentOverrideTruthTable() {
        let cases: [(String, String?, DisplayTransportChoice)] = [
            ("36.6.11.0", nil, .rawOnly),
            ("36.6.11.0", "raw", .rawOnly),
            ("36.6.11.0", "mmap", .rawOnly),
            ("36.6.11.0", "other", .rawOnly),
            ("37.1.11", nil, .mmapWithRawFallback),
            ("37.1.11", "raw", .rawOnly),
            ("37.1.11", "mmap", .mmapWithRawFallback),
            ("37.1.11", "other", .mmapWithRawFallback),
            ("unknown", nil, .rawOnly),
            ("unknown", "raw", .rawOnly),
            ("unknown", "mmap", .rawOnly),
            ("unknown", "other", .rawOnly),
        ]

        for (version, override, expected) in cases {
            let choice = DisplayTransportSelector.choose(
                emulatorVersion: version,
                transportOverride: override
            )
            #expect(choice == expected)
        }
    }
}

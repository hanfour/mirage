import Foundation
import Testing
@testable import MirageCore

@Suite("MirageResources")
struct MirageResourcesTests {
    @Test func resolvesBundleInMainResourcesDirectory() {
        let resourcesURL = URL(fileURLWithPath: "/tmp/Mirage.app/Contents/Resources", isDirectory: true)
        let expectedBundleURL = resourcesURL.appendingPathComponent("Mirage_MirageCore.bundle", isDirectory: true)

        let resolved = MirageResources.resolve(
            mainResourceURL: resourcesURL,
            fileExists: { $0 == expectedBundleURL }
        )

        #expect(resolved == expectedBundleURL)
    }

    @Test func returnsNilWhenBundleIsMissing() {
        let resourcesURL = URL(fileURLWithPath: "/tmp/Mirage.app/Contents/Resources", isDirectory: true)

        let resolved = MirageResources.resolve(mainResourceURL: resourcesURL, fileExists: { _ in false })

        #expect(resolved == nil)
    }
}

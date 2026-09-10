import Foundation
import Testing
@testable import MirageShell

struct LifecycleDiagnosticsTests {
    @Test func tokenEscapesFieldSeparators() {
        #expect(LifecycleDiagnostics.token("wake key=值\n") == "wake%20key%3D%E5%80%BC%0A")
        #expect(LifecycleDiagnostics.token("AZ09-_.:") == "AZ09-_.:")
    }

    @Test func missingObjectType() {
        #expect(LifecycleDiagnostics.typeName(nil) == "nil")
    }

    @Test func runtimeObjectType() {
        #expect(LifecycleDiagnostics.typeName(NSObject()) == "NSObject")
    }
}

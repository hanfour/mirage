// phase0/swift-poc/Sources/MiragePOC/main.swift
import Foundation

let client = try EmulatorClient()
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        print(try await client.status())
        print("OK: swift gRPC reachable")
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()

import Foundation
import GRPC

public enum BootProbe {
    public static func isBooted(endpoint: EmulatorEndpoint, timeout: Duration) async -> Bool? {
        let channel: GrpcChannelBox
        do {
            channel = try GrpcChannelBox(host: endpoint.host, port: endpoint.port)
        } catch {
            return nil
        }

        let client = channel.client
        var callOptions = client.defaultCallOptions
        let components = timeout.components
        let timeoutNanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        callOptions.timeLimit = .timeout(.nanoseconds(timeoutNanoseconds))

        return await firstOf(timeout: timeout) {
            defer { channel.shutdown() }
            do {
                let status = try await channel.client.getStatus(.init(), callOptions: callOptions)
                return status.booted
            } catch {
                return nil
            }
        }
    }
}

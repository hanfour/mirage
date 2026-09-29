import Foundation

public enum BootProbe {
    public static func isBooted(endpoint: EmulatorEndpoint, timeout: Duration) async -> Bool? {
        let channel: GrpcChannelBox
        do {
            channel = try GrpcChannelBox(host: endpoint.host, port: endpoint.port)
        } catch {
            return nil
        }
        defer { channel.shutdown() }
        return await GrpcHealthProbe(channel: channel).booted(timeout: timeout)
    }
}

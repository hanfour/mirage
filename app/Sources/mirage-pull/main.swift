import Darwin
import Foundation
import MiragePull

@main
struct MiragePullCommand {
    private struct Options {
        var endpoint = "localhost:8556"
        var seconds = 20
        var width = 900
        var height = 2000
        var transport = PullTransport.rgba
        var json = false
        var help = false

        init(arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--endpoint":
                    endpoint = try Self.nextValue(arguments, index: &index, flag: "--endpoint")
                case "--seconds":
                    let value = try Self.nextValue(arguments, index: &index, flag: "--seconds")
                    seconds = try Self.positiveInt(value, flag: "--seconds")
                case "--width":
                    let value = try Self.nextValue(arguments, index: &index, flag: "--width")
                    width = try Self.positiveInt(value, flag: "--width")
                case "--height":
                    let value = try Self.nextValue(arguments, index: &index, flag: "--height")
                    height = try Self.positiveInt(value, flag: "--height")
                case "--transport":
                    let value = try Self.nextValue(arguments, index: &index, flag: "--transport")
                    guard let selected = PullTransport(rawValue: value) else {
                        throw CommandLineError.invalidTransport(value)
                    }
                    transport = selected
                case "--json":
                    json = true
                case "--help", "-h":
                    help = true
                default:
                    throw CommandLineError.invalidArgument(arguments[index])
                }
                index += 1
            }
        }

        private static func nextValue(
            _ arguments: [String],
            index: inout Int,
            flag: String
        ) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw CommandLineError.missingValue(flag)
            }
            return arguments[index]
        }

        private static func positiveInt(_ value: String, flag: String) throws -> Int {
            guard let number = Int(value), number > 0 else {
                throw CommandLineError.invalidValue(flag, value)
            }
            return number
        }
    }

    private enum CommandLineError: Error, CustomStringConvertible {
        case invalidArgument(String)
        case missingValue(String)
        case invalidValue(String, String)
        case invalidTransport(String)

        var description: String {
            switch self {
            case .invalidArgument(let value): return "不支援的參數：\(value)"
            case .missingValue(let flag): return "參數缺少值：\(flag)"
            case .invalidValue(let flag, let value): return "\(flag) 必須是正整數：\(value)"
            case .invalidTransport(let value): return "--transport 只支援 rgba 或 mmap：\(value)"
            }
        }
    }

    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(usage)
                Darwin.exit(0)
            }

            let endpoint = try PullEndpoint(options.endpoint)
            let result = await MiragePull.run(
                endpoint: endpoint,
                duration: .seconds(Int64(options.seconds)),
                width: options.width,
                height: options.height,
                transport: options.transport
            )

            if options.json {
                do {
                    print(String(decoding: try result.jsonData(), as: UTF8.self))
                } catch {
                    writeError("JSON 輸出失敗：\(error)")
                    Darwin.exit(1)
                }
            } else {
                print(result.textLine)
            }
            Darwin.exit(Int32(result.exitCode))
        } catch {
            writeError("❌ \(error)")
            writeError(usage)
            Darwin.exit(2)
        }
    }

    private static let usage = "用法：mirage-pull [--endpoint host:port] [--seconds N] [--width N] [--height N] [--transport rgba|mmap] [--json]"

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

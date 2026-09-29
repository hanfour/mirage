import Foundation
import MirageCore
import Observation

enum SetupPhase: Equatable, Sendable {
    case intro
    case installing
    case succeeded
    case failed(item: String, reason: String)
}

enum SetupItemState: Equatable, Sendable {
    case waiting
    case downloading(Int64, Int64)
    case verifying
    case extracting
    case completed
    case failed(String)

    var logDescription: String {
        switch self {
        case .waiting: "等待中"
        case .downloading(let downloaded, let total): "下載中 \(downloaded)/\(total) bytes"
        case .verifying: "驗證中"
        case .extracting: "解壓縮中"
        case .completed: "完成"
        case .failed: "失敗"
        }
    }
}

struct SetupProgressItem: Equatable, Identifiable, Sendable {
    let key: String
    let name: String
    var state: SetupItemState
    var id: String { key }
}

@MainActor
@Observable
final class SetupController {
    let spec: SdkSpec
    let sdkRoot: URL
    let avdDirectory: URL
    let downloadsDirectory: URL
    var agreed = false
    var phase: SetupPhase = .intro
    var missingItems: [SetupMissingItem]
    var progressItems: [SetupProgressItem]
    var availableBytes: Int64
    var cancellationPending = false

    @ObservationIgnored private let installer: any PackageInstalling
    @ObservationIgnored private let readAvailableBytes: @MainActor () -> Int64
    @ObservationIgnored private let writeAVD: @MainActor () throws -> Void
    @ObservationIgnored private let evaluateSetup: @MainActor () -> SetupCheckResult
    @ObservationIgnored var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activeItemKey: String?

    init(
        spec: SdkSpec,
        missing: [SetupMissingItem],
        sdkRoot: URL,
        avdDirectory: URL,
        downloadsDirectory: URL,
        installer: any PackageInstalling,
        availableBytes: @escaping @MainActor () -> Int64,
        writeAVD: @escaping @MainActor () throws -> Void,
        evaluateSetup: (@MainActor () -> SetupCheckResult)? = nil
    ) {
        self.spec = spec
        self.sdkRoot = sdkRoot
        self.avdDirectory = avdDirectory
        self.downloadsDirectory = downloadsDirectory
        self.installer = installer
        readAvailableBytes = availableBytes
        self.availableBytes = availableBytes()
        self.writeAVD = writeAVD
        missingItems = missing
        self.evaluateSetup = evaluateSetup ?? {
            let manager = FileManager.default
            return SetupCheck.evaluate(
                spec: spec,
                sdkRoot: sdkRoot,
                avdDirectory: avdDirectory,
                fileExists: { manager.fileExists(atPath: $0.path) },
                readFile: { try String(contentsOf: $0, encoding: .utf8) })
        }
        progressItems = missing.map {
            SetupProgressItem(key: Self.key(for: $0), name: $0.name, state: .waiting)
        }
        for item in progressItems { log(item) }
    }

    var requiredBytes: Int64 { SetupSpace.required(for: evaluateSetup().missing) }

    var canStart: Bool {
        !cancellationPending && operationTask == nil
            && SetupGate.canStart(agreed: agreed, required: requiredBytes, available: availableBytes)
    }

    var remainingBytes: Int64 { max(0, requiredBytes - availableBytes) }

    func refreshAvailableSpace() {
        availableBytes = readAvailableBytes()
    }

    func start() {
        guard operationTask == nil, !cancellationPending, phase == .intro || isFailed else { return }
        let result = evaluateSetup()
        let required = SetupSpace.required(for: result.missing)
        refreshAvailableSpace()
        let allowed = SetupGate.canStart(agreed: agreed, required: required, available: availableBytes)
        print("[setup] gate canStart=\(allowed) required=\(required) available=\(availableBytes)")
        guard allowed else { return }

        generation += 1
        let currentGeneration = generation
        syncRows(with: result.missing)
        phase = .installing
        operationTask = Task { @MainActor [weak self] in
            await self?.run(missing: result.missing, generation: currentGeneration)
        }
    }

    func cancel() {
        guard phase == .installing else { return }
        generation += 1
        let cancelledTask = operationTask
        cancelledTask?.cancel()
        if let activeItemKey, let item = progressItems.first(where: { $0.key == activeItemKey }) {
            setState(.waiting, for: item.key)
        }
        activeItemKey = nil
        phase = .intro
        cancellationPending = true
        operationTask = Task { @MainActor [weak self] in
            await cancelledTask?.value
            guard let self else { return }
            self.syncRows(with: self.evaluateSetup().missing)
            self.refreshAvailableSpace()
            self.cancellationPending = false
            self.operationTask = nil
        }
    }

    func retry() {
        guard isFailed else { return }
        phase = .intro
        start()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func run(missing: [SetupMissingItem], generation runGeneration: Int) async {
        let packagePaths = Set(missing.compactMap { item -> String? in
            if case .package(let installPath) = item.kind { return installPath }
            return nil
        })

        for package in spec.packages where packagePaths.contains(package.installPath) {
            guard generation == runGeneration, !Task.isCancelled else { return }
            guard let item = progressItems.first(where: {
                if case .package(let path) = itemKind(for: $0.key) { return path == package.installPath }
                return false
            }) else { continue }
            activeItemKey = item.key
            setState(.downloading(0, package.size), for: item.key)
            do {
                try await installer.install(package, stage: { [weak self] stage in
                    await MainActor.run {
                        guard let self, self.generation == runGeneration else { return }
                        switch stage {
                        case .verifying: self.setState(.verifying, for: item.key)
                        case .extracting: self.setState(.extracting, for: item.key)
                        }
                    }
                }, progress: { [weak self] downloaded, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == runGeneration else { return }
                        guard let row = self.progressItems.first(where: { $0.key == item.key }),
                              case .downloading = row.state else { return }
                        self.setState(.downloading(downloaded, total), for: item.key)
                    }
                })
            } catch is CancellationError {
                return
            } catch {
                guard generation == runGeneration else { return }
                fail(item: item, reason: oneLine(error.localizedDescription))
                return
            }
            guard generation == runGeneration, !Task.isCancelled else { return }
            setState(.completed, for: item.key)
            activeItemKey = nil
        }

        if let avdItem = missing.first(where: {
            if case .avd = $0.kind { return true }
            return false
        }) {
            let key = Self.key(for: avdItem)
            activeItemKey = key
            setState(.verifying, for: key)
            do {
                try writeAVD()
            } catch {
                guard generation == runGeneration else { return }
                fail(item: progressItems.first(where: { $0.key == key }) ??
                     SetupProgressItem(key: key, name: avdItem.name, state: .waiting),
                     reason: oneLine(error.localizedDescription))
                return
            }
            guard generation == runGeneration, !Task.isCancelled else { return }
            setState(.completed, for: key)
            activeItemKey = nil
        }

        guard generation == runGeneration, !Task.isCancelled else { return }
        let final = evaluateSetup()
        for warning in final.warnings { print("[setup] warning \(warning.message)") }
        guard final.missing.isEmpty else {
            let remaining = final.missing[0]
            let row = progressItems.first(where: { $0.key == Self.key(for: remaining) }) ??
                SetupProgressItem(key: Self.key(for: remaining), name: remaining.name, state: .waiting)
            fail(item: row, reason: "重新檢查後仍缺少此項目")
            return
        }
        phase = .succeeded
        operationTask = nil
        print("[setup] done")
    }

    private func fail(item: SetupProgressItem, reason: String) {
        setState(.failed(reason), for: item.key)
        phase = .failed(item: item.name, reason: reason)
        operationTask = nil
        activeItemKey = nil
        print("[setup] failed \(item.name) \(reason)")
    }

    private func syncRows(with missing: [SetupMissingItem]) {
        missingItems = missing
        let missingKeys = Set(missing.map(Self.key(for:)))
        for index in progressItems.indices {
            if missingKeys.contains(progressItems[index].key) {
                setState(.waiting, for: progressItems[index].key)
            } else {
                setState(.completed, for: progressItems[index].key)
            }
        }
        for item in missing where !progressItems.contains(where: { $0.key == Self.key(for: item) }) {
            progressItems.append(SetupProgressItem(key: Self.key(for: item), name: item.name, state: .waiting))
            if let row = progressItems.last { log(row) }
        }
    }

    private func setState(_ state: SetupItemState, for key: String) {
        guard let index = progressItems.firstIndex(where: { $0.key == key }),
              progressItems[index].state != state else { return }
        progressItems[index].state = state
        log(progressItems[index])
    }

    private func log(_ item: SetupProgressItem) {
        print("[setup] \(item.name) \(item.state.logDescription)")
    }

    private func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func itemKind(for key: String) -> SetupMissingItem.Kind {
        if key.hasPrefix("package:") { return .package(installPath: String(key.dropFirst("package:".count))) }
        return .avd(name: String(key.dropFirst("avd:".count)))
    }

    private static func key(for item: SetupMissingItem) -> String {
        switch item.kind {
        case .package(let installPath): "package:\(installPath)"
        case .avd(let name): "avd:\(name)"
        }
    }
}

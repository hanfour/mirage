import AppKit
import MirageCore
import SwiftUI

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let controller: SetupController
    private let onSuccessfulClose: () -> Void
    private var createdWindow: NSWindow?
    private var mayClose = false

    init(controller: SetupController, onSuccessfulClose: @escaping () -> Void) {
        self.controller = controller
        self.onSuccessfulClose = onSuccessfulClose
    }

    func show() {
        let window: NSWindow
        if let createdWindow {
            window = createdWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "首次啟動設定"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupWizardView(
                controller: controller, windowController: self))
            window.center()
            window.delegate = self
            createdWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeAfterSuccess() {
        mayClose = true
        if let window = createdWindow {
            window.close()
            window.contentView = nil
            createdWindow = nil
        }
        onSuccessfulClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard mayClose else {
            NSApp.terminate(nil)
            return false
        }
        return true
    }
}

@MainActor
private struct SetupWizardView: View {
    @Bindable var controller: SetupController
    let windowController: SetupWindowController
    @State private var successCloseTask: Task<Void, Never>?

    private var downloadBytes: Int64 {
        controller.missingItems.reduce(Int64(0)) { total, item in total + item.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch controller.phase {
            case .intro:
                intro
            case .installing:
                installation
            case .succeeded:
                VStack(alignment: .leading, spacing: 8) {
                    Text("完成").font(.title2.weight(.semibold))
                    Text("Android 模擬器已準備好，Mirage 即將啟動。")
                        .foregroundStyle(.secondary)
                }
            case .failed(let item, let reason):
                VStack(alignment: .leading, spacing: 10) {
                    Text("設定失敗").font(.title2.weight(.semibold))
                    Text(item).font(.headline)
                    Text(reason).textSelection(.enabled)
                    Spacer(minLength: 0)
                    HStack {
                        Button("重試") { controller.retry() }
                            .keyboardShortcut(.defaultAction)
                        Spacer()
                        Button("結束 Mirage", role: .destructive) { NSApp.terminate(nil) }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 460, alignment: .topLeading)
        .onAppear {
            controller.refreshAvailableSpace()
            closeAfterSuccessIfNeeded()
        }
        .onChange(of: controller.phase) { _, _ in closeAfterSuccessIfNeeded() }
        .onDisappear { successCloseTask?.cancel() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("設定 Mirage").font(.title2.weight(.semibold))
            Text("Mirage 需要下載 Android 模擬器與系統映像。")
                .foregroundStyle(.secondary)
            Text("缺少項目").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.progressItems) { item in
                        HStack {
                            Text(item.name)
                            Spacer(minLength: 12)
                            HStack(spacing: 10) {
                                Text(stateText(item.state))
                                    .foregroundStyle(.secondary)
                                if itemSize(for: item.key) > 0 {
                                    Text(byteCount(itemSize(for: item.key)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            Text("下載大小：\(byteCount(downloadBytes))　需要空間：\(byteCount(controller.requiredBytes))")
            Text("目前可用：\(byteCount(controller.availableBytes))")
                .foregroundStyle(.secondary)
            if controller.remainingBytes > 0 {
                Text("空間不足，還差 \(byteCount(controller.remainingBytes))。")
                    .foregroundStyle(.red)
            }
            HStack(spacing: 6) {
                Button("Android SDK 授權條款") {
                    guard let url = URL(string: "https://developer.android.com/studio/terms") else { return }
                    NSWorkspace.shared.open(url)
                }
                Toggle("我同意", isOn: $controller.agreed)
                    .toggleStyle(.checkbox)
            }
            Spacer(minLength: 0)
            HStack {
                Button("開始") { controller.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canStart)
                Spacer()
                Button("結束 Mirage", role: .destructive) { NSApp.terminate(nil) }
            }
        }
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("正在設定 Mirage").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.progressItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline)
                            HStack {
                                Text(stateText(item.state))
                                Spacer()
                                if case .downloading(let downloaded, let total) = item.state {
                                    Text("\(byteCount(downloaded)) / \(byteCount(total))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if case .downloading(let downloaded, let total) = item.state, total > 0 {
                                ProgressView(value: Double(downloaded), total: Double(total))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消") { controller.cancel() }
            }
        }
    }

    private func itemSize(for key: String) -> Int64 {
        guard key.hasPrefix("package:") else { return 0 }
        let path = String(key.dropFirst("package:".count))
        return controller.spec.packages.first(where: { $0.installPath == path })?.size ?? 0
    }

    private func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private func stateText(_ state: SetupItemState) -> String {
        switch state {
        case .waiting: "等待中"
        case .downloading: "下載中"
        case .verifying: "驗證中"
        case .extracting: "解壓縮中"
        case .completed: "完成"
        case .failed(let reason): "失敗：\(reason)"
        }
    }

    private func closeAfterSuccessIfNeeded() {
        guard case .succeeded = controller.phase, successCloseTask == nil else { return }
        successCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            windowController.closeAfterSuccess()
        }
    }
}

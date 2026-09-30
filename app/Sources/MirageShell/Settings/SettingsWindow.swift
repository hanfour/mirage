import AppKit
import MirageCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let controller: SettingsController
    private let onClose: () -> Void
    private var createdWindow: NSWindow?

    init(controller: SettingsController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
    }

    func show() {
        let window: NSWindow
        if let createdWindow {
            window = createdWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AVD 設定：\(controller.avdName)"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            window.center()
            window.delegate = self
            createdWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            window.contentView = nil
        }
        createdWindow = nil
        onClose()
    }
}

@MainActor
private struct SettingsView: View {
    @Bindable var controller: SettingsController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                HStack {
                    Picker("CPU 核心數", selection: $controller.settings.cores) {
                        ForEach(controller.selectableCores, id: \.self) { value in
                            Text(controller.coreLabel(value)).tag(value)
                        }
                    }
                    Text("目前：\(controller.currentCoreLabel)")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .disabled(!controller.isEditable)

                HStack {
                    Picker("記憶體", selection: $controller.settings.ramMB) {
                        ForEach(controller.selectableRAM, id: \.self) { value in
                            Text(controller.ramLabel(value)).tag(value)
                        }
                    }
                    Text("目前：\(controller.currentRAMLabel)")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .disabled(!controller.isEditable)

                HStack {
                    Picker("解析度", selection: $controller.settings.resolution) {
                        ForEach(controller.selectableResolutions, id: \.self) { value in
                            Text(controller.resolutionLabel(value)).tag(value)
                        }
                    }
                    Text("目前：\(controller.currentResolutionLabel)")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .disabled(!controller.isEditable)
            }
            .formStyle(.grouped)

            if !controller.isEditable {
                Text("這個 AVD 不是由 Mirage 建立，請用 tools/provision/provision.py 管理")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let applyMessage = controller.applyMessage {
                Text(applyMessage).foregroundStyle(.secondary)
            }
            if let applyError = controller.applyError {
                Text(applyError).foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(controller.applyButtonTitle) {
                    Task { await controller.apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.isEditable)
            }
        }
        .padding(20)
        .frame(width: 560, height: 360, alignment: .topLeading)
    }
}

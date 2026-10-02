import AppKit
import MirageCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let avdController: SettingsController?
    private let locationController: LocationSettingsController
    private let avdError: String?
    private let initialLocationError: String?
    private let onClose: () -> Void
    private var createdWindow: NSWindow?

    init(avdController: SettingsController?,
         locationController: LocationSettingsController,
         avdError: String?,
         initialLocationError: String?,
         onClose: @escaping () -> Void) {
        self.avdController = avdController
        self.locationController = locationController
        self.avdError = avdError
        self.initialLocationError = initialLocationError
        self.onClose = onClose
    }

    func show() {
        let window: NSWindow
        if let createdWindow {
            window = createdWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Mirage 設定"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(
                avdController: avdController,
                locationController: locationController,
                avdError: avdError,
                initialLocationError: initialLocationError))
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
    let avdController: SettingsController?
    @Bindable var locationController: LocationSettingsController
    let avdError: String?
    let initialLocationError: String?

    var body: some View {
        Form {
            if let avdController {
                AVDSettingsSection(controller: avdController)
            }
            if let avdError {
                Text(avdError)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            LocationSettingsSection(
                controller: locationController,
                initialLoadError: initialLocationError)
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 720,
               minHeight: 420, idealHeight: 560, maxHeight: 760)
    }
}

@MainActor
private struct AVDSettingsSection: View {
    @Bindable var controller: SettingsController

    var body: some View {
        Section("AVD 設定") {
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

            if !controller.isEditable {
                Text("這個 AVD 不是由 Mirage 建立，請用 tools/provision/provision.py 管理")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let applyMessage = controller.applyMessage {
                Text(applyMessage).foregroundStyle(.secondary)
            }
            if let applyError = controller.applyError {
                Text(applyError).foregroundStyle(.red).textSelection(.enabled)
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
    }
}

@MainActor
private struct LocationSettingsSection: View {
    @Bindable var controller: LocationSettingsController
    let initialLoadError: String?

    var body: some View {
        Section("位置") {
            Toggle("使用自訂位置", isOn: $controller.enabled)
            LabeledContent("緯度") {
                TextField("例如 25.0339", text: $controller.latitudeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            LabeledContent("經度") {
                TextField("例如 121.5645", text: $controller.longitudeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            Text("高度 10 公尺，衛星數 12")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let initialLoadError {
                Text("讀取位置設定失敗：\(initialLoadError)")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let applyMessage = controller.applyMessage {
                Text(applyMessage).foregroundStyle(.secondary)
            }
            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("套用") {
                    Task { await controller.apply() }
                }
                .disabled(!controller.enabled)
            }

            Text("常用地點")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("地點名稱", text: $controller.favoriteName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    controller.saveFavorite()
                } label: {
                    Image(systemName: "plus")
                }
                .help("儲存目前座標")
                .accessibilityLabel("儲存目前座標")
            }

            ForEach(controller.favorites) { favorite in
                HStack(spacing: 8) {
                    Button {
                        Task { await controller.selectFavorite(favorite) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(favorite.name)
                            Text("\(favorite.coordinate.latitude), \(favorite.coordinate.longitude)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        controller.removeFavorite(id: favorite.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("刪除常用地點")
                    .accessibilityLabel("刪除 \(favorite.name)")
                }
            }
        }
    }
}

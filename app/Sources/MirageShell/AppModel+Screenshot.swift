import Foundation
import MirageCore

extension AppModel {
    func takeScreenshot() async {
        let result = await ScreenshotCapture.request(connState: connState) { await client.screenshotPNG() }
        switch result {
        case .skipped:
            print("[screenshot] skipped not-connected")
            showScreenshotNotice("截圖失敗：尚未連線")
        case .unavailable:
            failScreenshot("無法取得 PNG")
        case .png(let data):
            guard let upright = ScreenshotRotation.uprightPNG(data, rotation: displayRotation) else {
                failScreenshot("無法將截圖轉正")
                return
            }
            saveScreenshot(upright)
        }
    }

    func dismissScreenshotNotice(_ id: UUID) {
        guard screenshotNotice?.id == id else { return }
        screenshotNotice = nil
    }

    private func saveScreenshot(_ data: Data) {
        let environment = ProcessInfo.processInfo.environment
        let customDirectory = environment["MIRAGE_SCREENSHOT_DIR"].flatMap { path -> URL? in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
        let directory: URL
        if let customDirectory {
            directory = customDirectory
        } else if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            directory = desktop
        } else {
            failScreenshot("找不到桌面資料夾")
            return
        }

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = ScreenshotNaming.fileName(date: Date(), timeZone: .current)
            let destination = ScreenshotNaming.uniqueURL(directory: directory, base: base) {
                fileManager.fileExists(atPath: $0.path)
            }
            let temporary = directory.appendingPathComponent(".mirage-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            print("[screenshot] saved \(destination.path) bytes=\(data.count)")
            if let customDirectory {
                let folderName = customDirectory.lastPathComponent.isEmpty ? customDirectory.path : customDirectory.lastPathComponent
                showScreenshotNotice("已儲存到 \(folderName)")
            } else {
                showScreenshotNotice("已儲存到桌面")
            }
        } catch {
            failScreenshot(error.localizedDescription)
        }
    }

    private func failScreenshot(_ reason: String) {
        print("[screenshot] failed \(reason)")
        showScreenshotNotice("截圖失敗：\(reason)")
    }

    private func showScreenshotNotice(_ text: String) {
        screenshotNotice = ScreenshotNotice(text: text)
    }
}

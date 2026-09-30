import Foundation

enum ScreenshotNaming {
    static func fileName(date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Mirage 截圖 \(formatter.string(from: date)).png"
    }

    static func uniqueURL(directory: URL, base: String, exists: (URL) -> Bool) -> URL {
        let original = directory.appendingPathComponent(base, isDirectory: false)
        guard exists(original) else { return original }

        let stem = original.deletingPathExtension().lastPathComponent
        let fileExtension = original.pathExtension
        var suffix = 2
        while true {
            let name = fileExtension.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(fileExtension)"
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if !exists(candidate) { return candidate }
            suffix += 1
        }
    }
}

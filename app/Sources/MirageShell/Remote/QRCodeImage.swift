import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// CoreImage 的 `CIQRCodeGenerator` → `NSImage`，給選單列的 `NSMenuItem.view` 用。
/// 不引入任何第三方 QR 函式庫（spec 不做的事之外的隱含約束：零新依賴）。
enum QRCodeImage {
    private static let correctionLevel = "M"

    /// 原始輸出每個模組 1 pt，用仿射縮放放大；`CIImage.transformed` 對整數倍縮放是最近鄰，
    /// 邊緣不會糊掉，手機相機才掃得到。
    static func ciImage(_ text: String, side: CGFloat) -> CIImage? {
        guard side.isFinite, side > 0 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correctionLevel
        guard let image = filter.outputImage, image.extent.width > 0 else { return nil }
        // 模組只能整數倍放大；剩餘邊界用白色置中補齊，輸出仍精確等於 side。
        let scale = floor(side / image.extent.width)
        guard scale >= 1 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let inset = floor((side - scaled.extent.width) / 2)
        let centered = scaled.transformed(by: CGAffineTransform(translationX: inset, y: inset))
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return centered.composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)))
            .cropped(to: bounds)
    }

    static func make(_ text: String, side: CGFloat) -> NSImage? {
        guard let image = ciImage(text, side: side) else { return nil }
        let representation = NSCIImageRep(ciImage: image)
        let result = NSImage(size: NSSize(width: side, height: side))
        result.addRepresentation(representation)
        return result
    }
}

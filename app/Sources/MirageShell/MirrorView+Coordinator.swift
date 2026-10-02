import AppKit
import MirageCore
import SwiftUI

extension MirrorView {
    @MainActor
    final class Coordinator {
        let client: EmulatorClient
        var renderer: Renderer?
        var displayRotation = 0
        // P1-c：無 profile 時 sendMouse 退回直接 tap——spec §7 驗收 4，P1-a 行為不回歸。
        // D22：`hasProfile` 不再涵蓋編輯模式（見下面 `isEditing`），這句只談「有沒有 profile」。
        //
        // 原本這裡有一個 `frameSizeProvider` 的 didSet 佈線，把 renderer.lastFrameSize
        // 餵給 KeymapController 做觸點換算。整套已移除——換算收進 EmulatorClient 之後，
        // App 層不再需要（也不應該）知道該乘什麼尺寸。
        var controller: KeymapController?
        /// D22：編輯模式下一律不送滑鼠事件。與 `hasProfile` 是**兩件事**：
        /// 前者問「該不該交給引擎」，這個問「該不該送出去」。
        var isEditing = false
        var textMode = false
        private var isConnected = false
        private var mouseCaptureState: @MainActor () -> Bool = { false }
        private weak var mirrorView: MirrorMTKView?
        let queue: InputQueue
        private var resizeTask: Task<Void, Never>?
        private static let defaultStreamSize = (w: 540, h: 1200)
        private let onStreamDemand: @MainActor (Int, Int) async -> Void

        private var touchpadScrollEnabled: Bool {
            isConnected && !isEditing && !mouseCaptureState()
        }

        init(client: EmulatorClient, queue: InputQueue,
             onStreamDemand: @escaping @MainActor (Int, Int) async -> Void = { _, _ in }) {
            self.client = client
            self.queue = queue
            self.onStreamDemand = onStreamDemand
        }

        func bind(view: MirrorMTKView, controller: KeymapController?) {
            mirrorView = view
            if self.controller !== controller {
                self.controller?.onLoseFocus = nil
                self.controller = controller
                controller?.onLoseFocus = { [weak self] in self?.mirrorView?.cancelTouchpadDrag() }
            }
            view.isTouchpadScrollEnabled = { [weak self] in self?.touchpadScrollEnabled ?? false }
        }

        func updateTouchpadAvailability(connected: Bool, editing: Bool,
                                        mouseCaptured: @escaping @MainActor () -> Bool) {
            isConnected = connected
            isEditing = editing
            mouseCaptureState = mouseCaptured
            if !touchpadScrollEnabled { mirrorView?.cancelTouchpadDrag() }
        }

        func sendMouse(nx: Double, ny: Double, down: Bool) {
            sendMouse(nx: nx, ny: ny, down: down, fromTouchpad: false)
        }

        func sendMouse(nx: Double, ny: Double, down: Bool, fromTouchpad: Bool) {
            if fromTouchpad {
                if down { guard touchpadScrollEnabled else { return } }
                queue.tap(nx: nx, ny: ny, down: down)
                return
            }
            // D22：編輯中一律不送。使用者正在拖鍵位，不是在玩。
            guard !isEditing else { return }
            // 有作用中 profile 時鍵鼠改走 KeymapController → KeymapEngine，這裡不再重複送 tap。
            guard textMode || controller?.hasProfile != true else { return }
            // 直接送正規化座標：換算成 guest 像素需要**實體螢幕解析度**，那是
            // EmulatorClient 才知道的事（來自健康探測）。這裡原本用 lastFrameSize（串流
            // 幀尺寸）自行換算，而兩者在本機相差兩倍，所以每次點擊都偏到左上一半處。
            //
            // D6：走佇列而不是自己開 Task。原本 mouseDown/mouseUp 各開一個 Task，對調
            // 就是 guest 的手指永遠按著——與鍵盤直通同一種「沒有自癒路徑」的失效。
            queue.tap(nx: nx, ny: ny, down: down)
        }

        func resizeDebounced(to pixelSize: CGSize) {
            resizeTask?.cancel()
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // P1-e：長寬比改用實際解碼幀（原本硬編碼 h = w * 20 / 9，遊戲轉橫向就錯）。
                // 長寬比取 guest 解析度，幀只決定直橫，理由見 StreamSize.aspect。
                // 幀尺寸使用面板方向判斷來源比例，再依旋轉換成視窗需要的方向。
                let panelAspect = StreamSize.aspect(guest: await client.displaySize,
                                                    frame: renderer?.lastFrameSize ?? Self.defaultStreamSize)
                let aspect = DisplayRotation.upright(size: panelAspect, rotation: displayRotation)
                // 上限與偶數對齊的算術在 MirageCore.StreamSize（純函式、有單元測試）。
                let width = StreamSize.width(forContentWidth: Int(pixelSize.width), aspect: aspect)
                let height = StreamSize.height(forWidth: width, aspect: aspect)
                // 只換串流解析度。觸控座標**不隨它改變**——那是 guest 實體螢幕的事，
                // 由 EmulatorClient 從健康探測取得，與我們請求多大的畫面無關。
                await onStreamDemand(width, height)
            }
        }
    }
}

import AppKit
import MirageCore
import SwiftUI

extension MirrorView {
    @MainActor
    final class Coordinator {
        let client: EmulatorClient
        var renderer: Renderer?
        var displayRotation = 0
        var controller: KeymapController?
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
            guard !isEditing else { return }
            guard textMode || controller?.hasProfile != true else { return }
            queue.tap(nx: nx, ny: ny, down: down)
        }

        func resizeDebounced(to pixelSize: CGSize) {
            resizeTask?.cancel()
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // 幀尺寸使用面板方向判斷來源比例，再依旋轉換成視窗需要的方向。
                let panelAspect = StreamSize.aspect(guest: await client.displaySize,
                                                    frame: renderer?.lastFrameSize ?? Self.defaultStreamSize)
                let aspect = DisplayRotation.upright(size: panelAspect, rotation: displayRotation)
                let width = StreamSize.width(forContentWidth: Int(pixelSize.width), aspect: aspect)
                let height = StreamSize.height(forWidth: width, aspect: aspect)
                await onStreamDemand(width, height)
            }
        }
    }
}

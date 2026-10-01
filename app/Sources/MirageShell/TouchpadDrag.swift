import MirageCore

enum TouchpadScrollPhase: Equatable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

enum TouchpadDragAction: Equatable {
    case down(NormPoint)
    case move(NormPoint)
    case up(NormPoint)
}

struct TouchpadScrollSample {
    let phase: TouchpadScrollPhase
    let hasPreciseDeltas: Bool
    let hasPhase: Bool
    let hasMomentum: Bool
    let isEnabled: Bool
    let leftMouseDown: Bool
    let location: (x: Double, y: Double)
    let delta: (x: Double, y: Double)
    let size: (width: Double, height: Double)
}

/// 觸控板捲動序列轉成單指觸控，座標以正規化畫面為準。
struct TouchpadDragMachine {
    private(set) var currentPoint: NormPoint?
    var isDragging: Bool { currentPoint != nil }

    mutating func handle(_ sample: TouchpadScrollSample) -> [TouchpadDragAction] {
        guard !sample.leftMouseDown, sample.isEnabled else { return cancel() }
        guard sample.hasPreciseDeltas, sample.hasPhase, sample.phase != .none else { return [] }

        if sample.hasMomentum {
            // 有些系統會把手指放開與 momentumPhase=.began 放在同一事件。
            if sample.phase == .ended || sample.phase == .cancelled { return finish() }
            return []
        }

        switch sample.phase {
        case .began:
            guard let point = NormPoint.fromViewPoint(
                x: sample.location.x, y: sample.location.y,
                width: sample.size.width, height: sample.size.height
            ) else { return cancel() }
            var actions: [TouchpadDragAction] = []
            if let currentPoint { actions.append(.up(currentPoint)) }
            currentPoint = point
            actions.append(.down(point))
            return actions
        case .changed:
            guard let currentPoint,
                  sample.size.width > 0, sample.size.height > 0 else { return cancel() }
            // 正規化 y 原點在上，正 deltaY 表示畫面向下，guest y 隨之增加。
            let point = NormPoint.clamped(
                x: currentPoint.x + sample.delta.x / sample.size.width,
                y: currentPoint.y + sample.delta.y / sample.size.height
            )
            self.currentPoint = point
            return [.move(point)]
        case .ended, .cancelled:
            return finish()
        case .none:
            return []
        }
    }

    mutating func cancel() -> [TouchpadDragAction] { finish() }

    private mutating func finish() -> [TouchpadDragAction] {
        guard let currentPoint else { return [] }
        self.currentPoint = nil
        return [.up(currentPoint)]
    }
}

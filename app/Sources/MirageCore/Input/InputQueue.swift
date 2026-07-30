import Foundation

/// 輸入事件送往 `InputInjecting` 的唯一入口，**保證送出順序即到達順序**（債務 D6）。
///
/// **為什麼是這個形狀**：原本每個輸入事件各開一個 unstructured Task，於是「有幾個
/// 事件就有幾種可能的順序」。路上沒有任何一層擋得住——MainActor 排隊 → `EmulatorClient`
/// actor → 兩個各自獨立的 unary RPC，HTTP/2 跨 stream 不保證到達順序。修法不是加序號
/// 比對、不是加重試，那些都是在亂序發生之後才補救；這裡是把資料結構換掉，讓亂序在結構
/// 上不可能發生：**一條串流、一個消費者**，所以只有一種順序。
///
/// 這一條不變式同時修掉兩種形態的失效：
/// - **邊緣事件**（鍵盤直通的 down/up）對調＝guest 那顆鍵永遠按著，沒有自癒路徑，而且
///   汙染的是整個 guest 鍵盤輸入，不只當下那款遊戲。
/// - **全狀態快照**（`TouchFrame`）晚到的舊快照覆蓋新狀態＝幽靈觸點或吃掉動作，症狀
///   是「遊戲沒反應」——又一個看起來像遊戲問題的靜默錯誤。
public final class InputQueue: Sendable {
    private enum Command: Sendable {
        case key(KeyCode, down: Bool)
        case touches([TouchSpec])
        case tap(nx: Double, ny: Double, down: Bool)
    }

    private let cont: AsyncStream<Command>.Continuation

    public init(injector: any InputInjecting) {
        let (stream, cont) = AsyncStream.makeStream(of: Command.self)
        self.cont = cont
        // `Task.detached` 而非 `Task`：後者會繼承呼叫端的 actor（實際呼叫端
        // `AppModel` 是 @MainActor），讓這條幫浦白白掛在 MainActor 上，每個事件多一次
        // 來回跳躍。幫浦本身不碰任何 UI 狀態，沒有理由綁在任何 actor 上。
        Task.detached {
            for await command in stream {
                switch command {
                case .key(let code, let down): await injector.sendKey(code, down: down)
                case .touches(let specs):      await injector.sendTouches(specs)
                case .tap(let nx, let ny, let down): await injector.sendTap(nx: nx, ny: ny, down: down)
                }
            }
        }
    }

    /// 佇列擁有者消失時收掉幫浦，否則那個 Task 會連同 `injector` 一起永遠活著。
    /// 消費者 Task 只捕捉 `injector` 與 `stream`、不捕捉 `self`，所以 deinit 真的會到。
    deinit { cont.finish() }

    /// 送出不阻塞、不等待——`yield` 只是把命令排進串流。呼叫端（MainActor 上的輸入
    /// 事件處理）維持原本的「射後不理」語意，改變的只有到達順序的保證。
    public func key(_ code: KeyCode, down: Bool) {
        cont.yield(.key(code, down: down))
    }

    public func touches(_ specs: [TouchSpec]) {
        cont.yield(.touches(specs))
    }

    public func tap(nx: Double, ny: Double, down: Bool) {
        cont.yield(.tap(nx: nx, ny: ny, down: down))
    }
}

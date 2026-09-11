/// Fake RPC 立即返回；消費時才讀當下的 clipboard，故能重現 B/B。
struct DeferredPasteConsumer {
    var clipboard = ""
    var pending = 0
    var inserted: [String] = []
    mutating func setClipboard(_ value: String) { clipboard = value }
    mutating func pasteRPC() { pending += 1 }
    mutating func consumeOne() {
        precondition(pending > 0)
        inserted.append(clipboard)
        pending -= 1
    }
}

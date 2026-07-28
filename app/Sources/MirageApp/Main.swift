import MirageShell

/// executable 的全部內容。實作全在 `MirageShell` library，這裡只負責 `@main` 這個
/// 語言層的進入點——library target 不能帶 `@main`，而 App 層需要能被測試 import，
/// 兩個需求只能這樣拆。
@main
struct Main {
    @MainActor
    static func main() { MirageEntry.main() }
}

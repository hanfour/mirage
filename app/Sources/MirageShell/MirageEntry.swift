/// `MirageShell` 唯一的公開宣告——executable 的 `@main` 只呼叫這一個函式。
///
/// 這樣設計的理由：App 層 21 檔全部是 internal，測試靠 `@testable import` 觸及即可，
/// 沒有任何型別需要跨 module 公開。把公開面壓到一個函式，就不會有人為了「讓
/// executable 看得見」而逐步把內部型別改成 `public`。
public enum MirageEntry {
    @MainActor
    public static func main() { MirageScene.main() }
}

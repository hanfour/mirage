# Android Emulator 37.2.12 升級紀錄

環境：Apple Silicon（MacBookAir10,1）、macOS 26.6.2（25G83）。

## 升級原因

本機 37.1.11 的 `qemu-system-aarch64-headless` 崩潰報告顯示
`EXC_BAD_INSTRUCTION / SIGILL`，主執行緒停在 `init_cache_info`，由 dyld
執行初始化函式時觸發，尚未進入 Android 開機流程。

[官方 release notes](https://developer.android.com/studio/releases/emulator#37.2.12)
列出 37.2.12 Stable（2026-10-01），包含 Apple Silicon 的 gRPC
`streamScreenshot` MMAP 引擎崩潰修正。這項修正與 Mirage 的畫面傳輸有關，
但 release notes 未將 `init_cache_info` SIGILL 列為修正項目，不能據此判定根因。

## 套件

由 [Google SDK manifest](https://dl.google.com/android/repository/repository2-3.xml)
核對 macosx/aarch64、stable channel：

- Revision：37.2.12，Build ID：16428233
- URL：https://dl.google.com/android/repository/emulator-darwin_aarch64-16428233.zip
- 大小：416112708 bytes
- SHA-1：`3af4fe44ce82b3d88ae5678a53735f27ad729c15`

下載後已核對大小與 SHA-1。`sdk-spec.json` 同步更新以上四個欄位，供首次設定
與 Python provisioning 共用；依賴目前固定版本的測試預期也同步更新。

## 本機啟動檢查

從暫存目錄啟動 37.2.12，以 `-read-only -no-snapshot -no-window`
開啟既有 `mirage-poc`，啟用 token 驗證的 gRPC。28.5 秒內經 adb 取得
`sys.boot_completed=1`，隨後關閉檢查程序，這次未重現 SIGILL。

啟動檢查在 Codex 沙箱外執行，以取得 macOS 虛擬化所需權限；尚未對 37.1.11
在相同權限下做對照，因此目前只能確認新版在此條件下能開機。

本機 SDK 已安裝 37.2.12，provisioning 安裝紀錄同步更新；原套件保留於
`~/Library/Android/sdk/emulator.mirage-backup-37.1.11`。

正式 SDK 路徑下的 `mirage-game` 也以相同唯讀旗標完成開機，65.6 秒內取得
`sys.boot_completed=1`，隨後關閉檢查程序，未重現 SIGILL。

發布 PR 前的自動化檢查：

- `tools/provision`：`python3 -m unittest discover -s tests -t .`，113 項通過。
- `app`：`swift test --disable-sandbox --skip-build --filter 'SdkSpecTests|PackageInstallerTests'`，7 項通過；先前已成功建置這些測試。
- `git diff --check` 通過。

Swift 檢查使用 `/tmp` module cache 與 `--disable-sandbox`。最初在 Codex
沙箱內執行時，安裝器的 5 項測試因本機 HTTP server 無法 bind 而失敗；經
architect 唯讀診斷後，在沙箱外以相同編譯產物重跑，7 項全過。Python 完整
測試同樣在沙箱外執行，以允許測試用 loopback HTTP server 運作。

此檢查只涵蓋開機，不代表遊戲操作、音訊或 MMAP 串流已完成回歸驗證。

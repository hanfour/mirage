# 安裝 Mirage

## 系統需求

需要 Apple Silicon 的 Mac、macOS 14 或更新版本、網路連線，以及約 **17.4 GB 可用空間**。首次設定會下載約 2.2 GB 的 Android Emulator、Platform Tools 與 Google Play 系統映像；解壓與建立模擬器資料分割區還需要額外空間。實際需求會隨已安裝元件而降低，設定精靈會在開始前顯示估算值。

## 取得安裝檔

目前 GitHub 尚未發布可直接下載的安裝檔。若要自行建立，請在 Apple Silicon Mac 上執行：

```sh
git clone https://github.com/hanfour/mirage.git
cd mirage/app
./scripts/make_release.sh
```

完成後，安裝映像會輸出到 `app/dist/`，檔名依 `app/VERSION` 產生，例如 `Mirage-0.1.0.dmg`。此腳本預設建立未經 Apple 公證的映像；若 macOS 阻擋首次開啟，請依「系統設定」→「隱私權與安全性」顯示的選項允許開啟。

## 安裝

1. 打開下載的 Mirage `.dmg`。
2. 將 Mirage 拖到「應用程式」資料夾。

## 第一次打開

首次啟動時會出現設定精靈。閱讀並同意 Android SDK 授權條款後，按「開始」下載缺少的 Android 元件並建立模擬器。完成後 Android 會自動啟動。若安裝中斷，重新開啟 Mirage 可重試；已完成的元件會保留。

## Google Play

如要使用 Google Play，請在 Android 裡自行登入 Google 帳號。

## 移除

刪除「應用程式」資料夾中的 Mirage，再刪除以下兩個資料夾：

`~/Library/Application Support/Mirage`

`~/Library/Caches/Mirage`

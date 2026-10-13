# Mirage

Mirage 是為 Apple Silicon Mac 打造的 Android 遊戲模擬器，提供原生 macOS 視窗、鍵鼠操作、APK 拖放安裝與區域網路手機遙控。

## 安裝

目前還沒有可直接下載的 GitHub Release。你可以在 Apple Silicon Mac 上從原始碼建立安裝映像：

```sh
git clone https://github.com/hanfour/mirage.git
cd mirage/app
./scripts/make_release.sh
open dist/Mirage-*.dmg
```

完整系統需求、首次啟動設定與移除方式見[安裝指南](docs/install.md)。

## 開發

此專案需要 macOS 14 或更新版本。建置與測試說明及功能文件見 [app/README.md](app/README.md)。

# Mirage AVD Provisioning

在一台只有 Xcode CommandLineTools 的 Mac 上，把 Android SDK 與兩台 Mirage AVD
建到與 git 裡宣告的規格一致。**不需要 JDK**（`avdmanager`／`sdkmanager` 需要 Java，
本專案刻意不依賴它們）。

## 用法

    python3 provision.py              # 只報告，一行都不寫
    python3 provision.py --apply      # 另外覆寫已存在但不符的 AVD 設定
    python3 provision.py --upgrade    # 另外覆蓋已安裝但版本不符的 SDK package

缺失的東西一律直接裝。退出碼：`0` = 現況等於規格；`1` = 仍有漂移；`2` = 錯誤。

## 測試

    python3 -m unittest discover -s tests -t . -v

離線、零依賴、不下載任何東西。由 `app/scripts/ci.sh` 的閘門 6 執行。

## 會做與不會做

**不會**幫你登入 Google 帳號或安裝遊戲——那需要人。自動化的天花板是
「兩台一致的 AVD 可被重建」。遊戲請走 sideload（`app/scripts/verify_apk_install.sh`）
或人工登入。

## 升版

`lib/versions.py` 的 `PINS` 是唯一的版本來源。上游 bump 之後腳本會**主動報錯中止**
（manifest 對每個 package 只提供當下最新的一個 revision），這是設計而非故障：
它逼一個人來確認新版可用，並讓換環境留下 commit。

設計文件：`docs/specs/2026-07-31-d33-avd-provisioning-design.md`

import AppKit
import MirageCore

/// 模擬器多開（選項 B，docs/specs/2026-09-12-multi-instance-design.md §3.3）：
/// 多台各自開機，同一時間只有一台接 Mirage。切換 = stop → setEndpoint → start，
/// 靠既有的重連機制，沒有第二條生命週期。
///
/// 獨立成 extension 檔（比照 AppModel+FullScreen.swift）：AppModel.swift 本體已滿。
extension AppModel {
    /// 綁定選單列。子選單每次展開前重掃探索檔——與「套用 profile」掃目錄同一種即時性，
    /// 模擬器起停之後不必重開 App。
    func setupInstanceMenu() {
        menuBar?.instanceEntries = { [weak self] in
            guard let self else { return [] }
            return InstanceMenu.entries(instances: EmulatorDiscovery.instances(),
                                        current: self.currentEndpoint)
        }
        menuBar?.onSwitchInstance = { [weak self] instance in
            Task { @MainActor in await self?.switchInstance(to: instance) }
        }
    }

    /// 端點無論如何都印一行——「連到另一台」的症狀（畫面不是預期那台）跟「連不上」
    /// 長得完全不一樣，沒有這行只能靠猜。`start()` 與 `switchInstance` 共用。
    func logEndpoint(_ endpoint: EmulatorEndpoint) {
        let auth = EmulatorDiscovery.token(port: endpoint.port) == nil ? "none" : "token"
        print("[app] endpoint=\(endpoint.host):\(endpoint.port) auth=\(auth)")
    }

    /// 切到另一台。只換 gRPC 埠，host 沿用目前的——`MIRAGE_HOST` 覆寫不動，探索檔本來
    /// 也只描述本機實例。同一台 → 什麼都不做，不白白斷一次線。
    ///
    /// 切換期間 `client.states` 走 `.disconnected` → `.connecting` → `.connected`，
    /// Scene 上既有的 `ConnectionBanner` 就是進度畫面（規格 §3.3：不另做畫面）。
    /// 鍵位 profile 跟著遊戲偵測走、與實例無關，這裡不碰 keymap。
    func switchInstance(to instance: EmulatorInstance) async {
        // MainActor 在 await 會重入。每個要求先等前一個完成，再重新比對目前端點，
        // 避免快速點選時兩次 stop / setEndpoint / start 交錯、鏡像端點與 client 分歧。
        let previous = instanceSwitchTask
        let task = Task { @MainActor in
            await previous?.value
            await self.performInstanceSwitch(to: instance)
        }
        instanceSwitchTask = task
        await task.value
    }

    private func performInstanceSwitch(to instance: EmulatorInstance) async {
        guard instance.grpcPort != currentEndpoint.port else { return }
        let target = EmulatorEndpoint(host: currentEndpoint.host, port: instance.grpcPort)
        let size = await client.requestedStreamSize
        await client.stop()
        guard await client.setEndpoint(target) else {
            // stop() 回來時迴圈已結束（EmulatorClient.stop 的說明），這條不該走到；
            // 走到了要有訊號，不能靜默留在舊那台。
            print("[app] 切換到 \(instance.avdName) 失敗：client 仍在跑，維持 \(currentEndpoint.host):\(currentEndpoint.port)")
            return
        }
        currentEndpoint = target
        logEndpoint(target)
        await client.start(box: activeSink, width: size.w, height: size.h)
    }
}

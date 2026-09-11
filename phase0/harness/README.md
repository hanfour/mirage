# Phase 0 harness

此目錄的 Python 腳本使用 `grpc.insecure_channel` 直接連線，不帶 token。
連到以 `-grpc-use-token` 啟動的模擬器時，會收到 `UNAUTHENTICATED`。
要使用這些腳本，請以不帶 `-grpc-use-token` 的方式啟動模擬器。

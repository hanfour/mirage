#!/usr/bin/env bash
# 產生 SnapshotService 的 Swift gRPC + message stub。
# 前置：protoc、protoc-gen-swift（brew）已裝；protoc-gen-grpc-swift 由 grpc-swift 1.27.5 build。
set -euo pipefail
cd "$(dirname "$0")/.."                       # → app/
SDK_LIB="$HOME/Library/Android/sdk/emulator/lib"
GEN="Sources/MirageCore/Generated"
PLUGIN_SRC=".build/checkouts/grpc-swift"

# 1) build 版本匹配的 grpc-swift protoc plugin（首次 ~1-2 分鐘）
swift build --package-path "$PLUGIN_SRC" --product protoc-gen-grpc-swift -c release
PLUGIN_BIN="$PLUGIN_SRC/.build/release/protoc-gen-grpc-swift"
test -x "$PLUGIN_BIN" || { echo "FAIL: protoc-gen-grpc-swift 未 build 出"; exit 1; }

# 2) 產生 message（.pb.swift）與 service（.grpc.swift）
protoc \
  --proto_path="$SDK_LIB" \
  --plugin=protoc-gen-grpc-swift="$PLUGIN_BIN" \
  --swift_opt=Visibility=Public \
  --swift_out="$GEN" \
  --grpc-swift_opt=Visibility=Public,Client=true,Server=false \
  --grpc-swift_out="$GEN" \
  "$SDK_LIB/snapshot_service.proto" "$SDK_LIB/snapshot.proto"

echo "OK: 產生於 $GEN/"
ls -1 "$GEN"/snapshot*.swift

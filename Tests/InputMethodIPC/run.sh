#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ipc_build="$(mktemp -d "${TMPDIR:-/tmp}/haiwang-ipc-build.XXXXXX")"
trap 'rm -rf "$ipc_build"' EXIT
ipc_arch="$(uname -m)"
ipc_sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$ipc_build/ModuleCache"

compiler_flags=(
  -swift-version 5
  -target "$ipc_arch-apple-macos26.0"
  -sdk "$ipc_sdk"
  -module-cache-path "$ipc_build/ModuleCache"
)

xcrun swiftc "${compiler_flags[@]}" \
  -emit-library -emit-module -module-name HaiwangCore \
  -emit-module-path "$ipc_build/HaiwangCore.swiftmodule" \
  "$project_root"/Sources/HaiwangCore/*.swift \
  -o "$ipc_build/libHaiwangCore.dylib"

xcrun swiftc "${compiler_flags[@]}" \
  -parse-as-library -module-name HaiwangInputMethodIPCSmoke \
  -I "$ipc_build" -L "$ipc_build" -lHaiwangCore \
  -Xlinker -rpath -Xlinker "$ipc_build" \
  "$project_root"/SharedRuntime/*.swift \
  "$project_root/macOS/App/InputMethodTranslationHost.swift" \
  "$project_root/Tests/InputMethodIPC/main.swift" \
  -o "$ipc_build/input-method-ipc-smoke"

# Isolated sockets under /tmp; no UI, language downloads, saved preferences,
# clipboard access, credentials, or external translation requests.
"$ipc_build/input-method-ipc-smoke"

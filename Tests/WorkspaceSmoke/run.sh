#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
smoke_build="${HAIWANG_WORKSPACE_SMOKE_BUILD:-$HOME/Library/Developer/Haiwang/WorkspaceSmoke}"
smoke_arch="$(uname -m)"
smoke_sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$smoke_build/ModuleCache"

compiler_flags=(
  -target "$smoke_arch-apple-macos26.0"
  -sdk "$smoke_sdk"
  -module-cache-path "$smoke_build/ModuleCache"
)

# Build the real core and shared workspace code into this isolated output directory.
xcrun swiftc "${compiler_flags[@]}" \
  -emit-library -emit-module -module-name HaiwangCore \
  -emit-module-path "$smoke_build/HaiwangCore.swiftmodule" \
  "$project_root"/Sources/HaiwangCore/*.swift \
  -o "$smoke_build/libHaiwangCore.dylib"

xcrun swiftc "${compiler_flags[@]}" \
  -parse-as-library -module-name HaiwangWorkspaceSmoke \
  -I "$smoke_build" -L "$smoke_build" -lHaiwangCore \
  -Xlinker -rpath -Xlinker "$smoke_build" \
  "$project_root"/SharedUI/*.swift \
  "$project_root"/SharedRuntime/*.swift \
  "$project_root/Tests/WorkspaceSmoke/main.swift" \
  -o "$smoke_build/workspace-smoke"

# These are process-local overrides; they do not change the system's language settings.
"$smoke_build/workspace-smoke" -AppleLanguages '(en)'
"$smoke_build/workspace-smoke" -AppleLanguages '(zh-Hans)' --expect-chinese

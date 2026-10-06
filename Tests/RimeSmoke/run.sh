#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$project_root/Tests/RimeSmoke/.build"
mkdir -p "$test_root"
xcrun swiftc -typecheck \
  -import-objc-header "$project_root/Native/RimeBridge/HQPinyinEngine.h" \
  "$project_root/Tests/RimeSmoke/Interface.swift"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
  -framework Foundation \
  -I "$project_root/Native/RimeBridge" \
  -I "$project_root/Vendor/librime/dist/include" \
  "$project_root/Native/RimeBridge/HQPinyinEngine.m" \
  "$project_root/Tests/RimeSmoke/main.m" \
  -L "$project_root/Vendor/librime/dist/lib" -lrime \
  -Wl,-rpath,"$project_root/Vendor/librime/dist/lib" \
  -o "$test_root/RimeSmoke"
test_user="$test_root/user-$(uuidgen)"
"$test_root/RimeSmoke" "$project_root/Vendor/RimeData" "$test_user"

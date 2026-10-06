#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_TEST_BASE="${HAIWANG_INPUTMETHOD_SMOKE_ROOT:-$HOME/Library/Developer/Haiwang/InputMethodSmoke}"
if [[ "$TASK_TEST_BASE" != /* || "$TASK_TEST_BASE" == *"/Mobile Documents/"* || "$TASK_TEST_BASE" == *"/CloudStorage/"* ]]; then
  echo "测试构建目录必须是非 iCloud 的本机绝对路径：$TASK_TEST_BASE" >&2
  exit 1
fi
if [[ ! -f "$TASK_ROOT/Vendor/librime/dist/include/rime_api.h" || ! -f "$TASK_ROOT/Vendor/RimeData/luna_pinyin_simp.schema.yaml" ]]; then
  echo "缺少本项目固定版本的 Rime；请先运行 scripts/fetch-rime.sh。测试本身不会下载。" >&2
  exit 1
fi
mkdir -p "$TASK_TEST_BASE"
TASK_RUN=$(mktemp -d "$TASK_TEST_BASE/run.XXXXXX")
TASK_APP="$TASK_RUN/InputMethodSmoke.app"
TASK_CONTENTS="$TASK_APP/Contents"
TASK_FRAMEWORKS="$TASK_CONTENTS/Frameworks"
mkdir -p "$TASK_CONTENTS/MacOS" "$TASK_CONTENTS/Resources" "$TASK_FRAMEWORKS" "$TASK_RUN/modules"
TASK_ARCH=$(uname -m)
TASK_TARGET="$TASK_ARCH-apple-macosx26.0"
cat > "$TASK_CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.haiwang.tests.InputMethodSmoke</string>
<key>CFBundleName</key><string>InputMethodSmoke</string>
<key>CFBundleExecutable</key><string>InputMethodSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
ditto --noextattr --norsrc --noqtn "$TASK_ROOT/Vendor/RimeData" "$TASK_CONTENTS/Resources/RimeData"
ditto --noextattr --norsrc --noqtn "$TASK_ROOT/Vendor/librime/dist/lib/librime.1.dylib" "$TASK_FRAMEWORKS/librime.1.dylib"
xcrun swiftc -swift-version 6 -target "$TASK_TARGET" -parse-as-library \
  -emit-library -emit-module -module-name HaiwangCore \
  -emit-module-path "$TASK_RUN/modules/HaiwangCore.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/libHaiwangCore.dylib' \
  "$TASK_ROOT"/Sources/HaiwangCore/*.swift \
  -o "$TASK_FRAMEWORKS/libHaiwangCore.dylib"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=26.0 \
  -I "$TASK_ROOT/Native/RimeBridge" -I "$TASK_ROOT/Vendor/librime/dist/include" \
  -c "$TASK_ROOT/Native/RimeBridge/HQPinyinEngine.m" -o "$TASK_RUN/HQPinyinEngine.o"
xcrun swiftc -D DEBUG -swift-version 5 -target "$TASK_TARGET" -parse-as-library \
  -import-objc-header "$TASK_ROOT/Native/RimeBridge/HQPinyinEngine.h" \
  -I "$TASK_RUN/modules" -L "$TASK_FRAMEWORKS" -lHaiwangCore \
  -L "$TASK_ROOT/Vendor/librime/dist/lib" -lrime \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -framework AppKit -framework Carbon -framework InputMethodKit \
  "$TASK_ROOT/macOS/InputMethod/HaiwangInputController.swift" \
  "$TASK_ROOT/macOS/InputMethod/CandidatePanel.swift" \
  "$TASK_ROOT/Tests/InputMethodSmoke/MockInputClient.swift" \
  "$TASK_ROOT/Tests/InputMethodSmoke/OfflineTranslationStub.swift" \
  "$TASK_ROOT/Tests/InputMethodSmoke/main.swift" "$TASK_RUN/HQPinyinEngine.o" \
  -o "$TASK_CONTENTS/MacOS/InputMethodSmoke" > "$TASK_RUN/compile.log" 2>&1 || {
    tail -80 "$TASK_RUN/compile.log"
    exit 1
  }
xattr -cr "$TASK_APP"
codesign --force --deep --sign - "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
echo "运行真实输入控制器的离线测试；独立构建和词库：$TASK_RUN"
"$TASK_CONTENTS/MacOS/InputMethodSmoke" "$TASK_RUN/user-data" 2>&1 | tee "$TASK_RUN/result.log"

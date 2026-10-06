#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD_ROOT="${HAIWANG_BUILD_ROOT:-$HOME/Library/Developer/Haiwang}"
TASK_SOURCE="$TASK_BUILD_ROOT/BuildSource"
TASK_DERIVED="${HAIWANG_DERIVED_DATA:-$TASK_BUILD_ROOT/DerivedData}"
TASK_OUTPUT="${HAIWANG_OUTPUT_DIR:-$HOME/Library/Developer/Haiwang/Preview}"

for TASK_PATH in "$TASK_BUILD_ROOT" "$TASK_DERIVED" "$TASK_OUTPUT"; do
  if [[ "$TASK_PATH" != /* || "$TASK_PATH" == / || "$TASK_PATH" == "$HOME" || "$TASK_PATH" == "$TASK_ROOT" || "$TASK_PATH" == *"/Mobile Documents/"* || "$TASK_PATH" == *"/CloudStorage/"* ]]; then
    echo "构建目录必须为非 iCloud 的本机绝对路径：$TASK_PATH" >&2
    exit 1
  fi
done
if [[ -d "$TASK_SOURCE" && ! -f "$TASK_SOURCE/.haiwang-source-mirror" && -n "$(ls -A "$TASK_SOURCE")" ]]; then
  echo "拒绝覆盖未经标记的源目录：$TASK_SOURCE" >&2
  exit 1
fi
mkdir -p "$TASK_SOURCE" "$TASK_OUTPUT" "$TASK_ROOT/build" "$TASK_BUILD_ROOT/Tools"
# Xcode registers macOS application products unconditionally. Unregistering a
# duplicate IME can remove the installed source from the user's keyboard list.
# Build in a separate login session when the production input source is enabled.
if [[ -d "$HOME/Library/Input Methods/海王输入法键盘.app" ]]; then
  TASK_QUERY_DIR=$(mktemp -d "$TASK_BUILD_ROOT/Tools/.build-input-query.XXXXXX")
  xcrun swiftc "$TASK_ROOT/scripts/input-sources.swift" -o "$TASK_QUERY_DIR/input-sources"
  "$TASK_QUERY_DIR/input-sources" list --all --bundle haiwang > "$TASK_QUERY_DIR/sources.json"
  TASK_INPUT_ENABLED=$(python3 - "$TASK_QUERY_DIR/sources.json" <<'PY'
import json, sys
sources = json.load(open(sys.argv[1]))
print('true' if any(s['id'] == 'com.haiwang.inputmethod.Haiwang' and s['enabled'] for s in sources) else 'false')
PY
  )
  rm "$TASK_QUERY_DIR/input-sources" "$TASK_QUERY_DIR/sources.json"
  rmdir "$TASK_QUERY_DIR"
  if [[ "$TASK_INPUT_ENABLED" == true ]]; then
    echo "当前登录会话已启用出海王。为保护系统键盘列表，请在独立的用户会话中构建。" >&2
    echo "已有预览产物可通过 scripts/package-release.sh 打包；打包不会重新登记输入源。" >&2
    exit 1
  fi
fi
touch "$TASK_SOURCE/.haiwang-source-mirror"

# Build and sign outside iCloud; rsync only replaces this marked generated source mirror.
rsync -a --delete \
  --exclude='/.haiwang-source-mirror' --exclude='/.git/' --exclude='/build/' \
  --exclude='.build/' --exclude='/DerivedData/' --exclude='**/.DS_Store' \
  "$TASK_ROOT/" "$TASK_SOURCE/"
xattr -cr "$TASK_SOURCE"
cd "$TASK_SOURCE"
# Generate the current App/IME artwork in the local source mirror before compiling.
# The menu TIFF and the ICNS must come from the same checked-in icon generator.
xcrun swift scripts/generate-icons.swift "$TASK_SOURCE" > "$TASK_ROOT/build/icon-generation.log" 2>&1 || {
  cat "$TASK_ROOT/build/icon-generation.log"
  exit 1
}
xcrun iconutil -c icns "$TASK_SOURCE/build/Haiwang.iconset" -o "$TASK_SOURCE/macOS/Resources/AppIcon.icns" \
  >> "$TASK_ROOT/build/icon-generation.log" 2>&1 || {
    cat "$TASK_ROOT/build/icon-generation.log"
    exit 1
  }
xcodegen generate > "$TASK_ROOT/build/project-generation.log" 2>&1
# Preserve prior generated products and start with fresh bundles; compiler caches remain.
mkdir -p "$TASK_BUILD_ROOT/ProductBackups"
TASK_PRODUCTS_BACKUP=$(mktemp -d "$TASK_BUILD_ROOT/ProductBackups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
for TASK_APP in 海王输入法.app 海王输入法键盘.app 出海王输入法.app 出海王输入法键盘.app; do
  if [[ -e "$TASK_DERIVED/Build/Products/Release/$TASK_APP" ]]; then
    mv "$TASK_DERIVED/Build/Products/Release/$TASK_APP" "$TASK_PRODUCTS_BACKUP/$TASK_APP"
  fi
done

TASK_BUILD_FAILED=false
for TASK_SCHEME in HaiwangMac HaiwangInputMethod; do
  TASK_LOG="$TASK_ROOT/build/$TASK_SCHEME-release-build.log"
  echo "正在构建 ${TASK_SCHEME}…"
  xcodebuild -project Haiwang.xcodeproj -scheme "$TASK_SCHEME" -configuration Release \
    -derivedDataPath "$TASK_DERIVED" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build > "$TASK_LOG" 2>&1 || {
      rg -n 'error:|fatal error:|BUILD FAILED|^The following build commands failed' "$TASK_LOG" || tail -40 "$TASK_LOG"
      TASK_BUILD_FAILED=true
    }
done
# Xcode registers fresh app bundles even with an unsigned build. Unregister only
# this build's exact products, then restore the signed installed launch paths.
# Do not delete products, old versions, preferences or other registration records.
TASK_LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TASK_REGISTRATION_LOG="$TASK_ROOT/build/launch-services-after-build.log"
: > "$TASK_REGISTRATION_LOG"
for TASK_RELATIVE_APP in 出海王输入法.app 出海王输入法键盘.app 出海王输入法.app/Contents/Library/InputMethodInstaller/出海王输入法键盘.app; do
  TASK_BUILT_APP="$TASK_DERIVED/Build/Products/Release/$TASK_RELATIVE_APP"
  [[ -d "$TASK_BUILT_APP" ]] || continue
  TASK_EXPECTED_ID=com.haiwang.inputmethod.Haiwang
  if [[ "$TASK_RELATIVE_APP" == 出海王输入法.app ]]; then TASK_EXPECTED_ID=com.haiwang.app; fi
  TASK_ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_BUILT_APP/Contents/Info.plist")
  [[ "$TASK_ACTUAL_ID" == "$TASK_EXPECTED_ID" ]] || { echo "构建产物标识不匹配，拒绝更改登记：$TASK_BUILT_APP" >&2; exit 1; }
  "$TASK_LSREGISTER" -u "$TASK_BUILT_APP" >> "$TASK_REGISTRATION_LOG" 2>&1 || true
done
for TASK_INSTALLED_APP in "$HOME/Applications/出海王输入法.app" "$HOME/Library/Input Methods/海王输入法键盘.app"; do
  [[ -d "$TASK_INSTALLED_APP" ]] || continue
  TASK_EXPECTED_ID=com.haiwang.inputmethod.Haiwang
  if [[ "$TASK_INSTALLED_APP" == "$HOME/Applications/出海王输入法.app" ]]; then TASK_EXPECTED_ID=com.haiwang.app; fi
  TASK_ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_INSTALLED_APP/Contents/Info.plist")
  if [[ "$TASK_ACTUAL_ID" == "$TASK_EXPECTED_ID" ]] && codesign --verify --deep --strict "$TASK_INSTALLED_APP" >> "$TASK_REGISTRATION_LOG" 2>&1; then
    "$TASK_LSREGISTER" -f "$TASK_INSTALLED_APP" >> "$TASK_REGISTRATION_LOG" 2>&1
  fi
done
if [[ "$TASK_BUILD_FAILED" == true ]]; then exit 1; fi

TASK_STAGE=$(mktemp -d "$TASK_OUTPUT/.haiwang-build.XXXXXX")
for TASK_APP in 出海王输入法.app 出海王输入法键盘.app; do
  ditto --noextattr --norsrc --noqtn "$TASK_DERIVED/Build/Products/Release/$TASK_APP" "$TASK_STAGE/$TASK_APP"
  xattr -cr "$TASK_STAGE/$TASK_APP"
done
xcrun swiftc scripts/input-sources.swift -o "$TASK_STAGE/haiwang-input-sources"
codesign --force --sign - "$TASK_STAGE/haiwang-input-sources"
codesign --verify --strict "$TASK_STAGE/haiwang-input-sources"
# Library/InputMethodInstaller is not a standard codesign nested-code directory.
# Sign its payload explicitly, inside out; --deep on the host alone skips it.
codesign --force --deep --sign - "$TASK_STAGE/出海王输入法键盘.app"
codesign --verify --deep --strict "$TASK_STAGE/出海王输入法键盘.app"
TASK_EMBEDDED="$TASK_STAGE/出海王输入法.app/Contents/Library/InputMethodInstaller"
mkdir -p "$TASK_EMBEDDED"
ditto --noextattr --norsrc --noqtn "$TASK_STAGE/出海王输入法键盘.app" "$TASK_EMBEDDED/出海王输入法键盘.app"
cp "$TASK_STAGE/haiwang-input-sources" "$TASK_EMBEDDED/haiwang-input-sources"
cp scripts/install-input-method.sh "$TASK_EMBEDDED/install-input-method.sh"
chmod +x "$TASK_EMBEDDED/install-input-method.sh"
codesign --verify --deep --strict "$TASK_EMBEDDED/出海王输入法键盘.app"
codesign --verify --strict "$TASK_EMBEDDED/haiwang-input-sources"
codesign --force --deep --sign - "$TASK_STAGE/出海王输入法.app"
codesign --verify --deep --strict "$TASK_STAGE/出海王输入法.app"
cp scripts/install-input-method.sh "$TASK_STAGE/安装输入法.command"
chmod +x "$TASK_STAGE/安装输入法.command"
cat > "$TASK_STAGE/使用说明.txt" <<'EOF'
出海王输入法（macOS 26+ / Apple Silicon，开发测试版）

双击“安装输入法.command”安装当前用户的 App 和系统输入法，并启用出海王。
也可只把“出海王输入法.app”放入应用程序并打开；首次启动的新手设置会安装内置输入法组件。
跟随引导加入系统键盘，再用试打框输入 nihao 并按空格确认“你好”。
普通拼音和英文无需下载翻译模型；翻译功能可在试打完成后按需准备。
暂时跳过后，可在使用指南、设置或“跨语言输入”菜单中重新打开新手设置。
安装前保留精确旧版备份及当前输入源快照，安装完成后恢复原输入源。
更新时会暂时切出出海王并退出旧进程，安装后恢复原输入源、重新打开新 App。
首次安装若显示“系统尚未确认”，请在自动打开的系统设置中完成添加：
键盘 → 文本输入 → 编辑 → ＋ → 简体中文 → 出海王输入法 → 添加。
只需一个出海王输入源；轻按 Shift 切换中文拼音／英文直输。
也可用 Control + Shift + 空格、输入法菜单或候选栏“中／英”按钮切换。
升级时会移除旧版独立的海王·英文，并把原先选中的英文源迁移至出海王。
安装器读取父输入源与单一出海王源的真实状态，系统列表尚待调整时退出码为 2。
待调整不会回滚已经成功安装的文件；系统已经启用出海王时可直接使用。
App 不再占用菜单栏图标；可从输入法菜单打开工作台，或按 Option + Space 打开面板。
支持普通中文拼音、英文输入及翻译输入；翻译使用 Apple 内置或本机模型。
拖动候选窗口顶部标题或原文区域固定位置，下次输入和重启后仍保留；点击取消固定按钮可恢复跟随光标。
可用语言对以设备实际安装的语言包或本地模型为准。
EOF
TASK_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_STAGE/出海王输入法.app/Contents/Info.plist")
ditto -c -k --norsrc "$TASK_STAGE" "$TASK_ROOT/build/SailKing-$TASK_VERSION-macOS-arm64.zip"
cp "$TASK_STAGE/haiwang-input-sources" "$TASK_BUILD_ROOT/Tools/haiwang-input-sources"
mkdir -p "$TASK_BUILD_ROOT/GeneratedPreviewBackups"
TASK_OLD_PREVIEW=$(mktemp -d "$TASK_BUILD_ROOT/GeneratedPreviewBackups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
for TASK_LEGACY_ITEM in 海王输入法.app 海王输入法键盘.app; do
  if [[ -e "$TASK_OUTPUT/$TASK_LEGACY_ITEM" ]]; then mv "$TASK_OUTPUT/$TASK_LEGACY_ITEM" "$TASK_OLD_PREVIEW/$TASK_LEGACY_ITEM"; fi
done
for TASK_ITEM in 出海王输入法.app 出海王输入法键盘.app haiwang-input-sources 安装输入法.command 使用说明.txt; do
  # Move whole generated bundles so obsolete resources cannot survive a rebuild.
  # Installed applications are updated separately by the installer.
  if [[ -e "$TASK_OUTPUT/$TASK_ITEM" ]]; then mv "$TASK_OUTPUT/$TASK_ITEM" "$TASK_OLD_PREVIEW/$TASK_ITEM"; fi
  mv "$TASK_STAGE/$TASK_ITEM" "$TASK_OUTPUT/$TASK_ITEM"
done
rmdir "$TASK_STAGE"
echo "构建完成：${TASK_OUTPUT}（App + 系统输入法，本地签名）"
echo "安装包：$TASK_ROOT/build/SailKing-$TASK_VERSION-macOS-arm64.zip"

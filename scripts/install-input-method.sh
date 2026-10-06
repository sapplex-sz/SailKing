#!/bin/bash
set -euo pipefail
TASK_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_PREVIEW="${HAIWANG_OUTPUT_DIR:-$HOME/Library/Developer/Haiwang/Preview}"
if [[ -x "$TASK_SCRIPT_DIR/haiwang-input-sources" ]]; then
  TASK_PREVIEW="$TASK_SCRIPT_DIR"
fi
TASK_OPEN=true
TASK_INPUT_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open) TASK_OPEN=false; shift ;;
    --input-method-only) TASK_INPUT_ONLY=true; TASK_OPEN=false; shift ;;
    --source-dir)
      [[ $# -ge 2 ]] || { echo "--source-dir 需要路径。" >&2; exit 1; }
      TASK_PREVIEW="$2"; shift 2 ;;
    *) echo "用法：bash scripts/install-input-method.sh [--no-open] [--input-method-only] [--source-dir 构建目录]" >&2; exit 1 ;;
  esac
done
TASK_INPUT_SOURCE="$TASK_PREVIEW/出海王输入法键盘.app"
TASK_APP_SOURCE="$TASK_PREVIEW/出海王输入法.app"
TASK_TOOL="$TASK_PREVIEW/haiwang-input-sources"
# Keep the input method's internal installed filename stable. macOS can retain
# stale input-source catalog paths after a rename, even when TIS reports success.
# The bundle's localized display name and menu name are 出海王输入法 / SailKing.
TASK_INPUT_TARGET="$HOME/Library/Input Methods/海王输入法键盘.app"
TASK_APP_TARGET="$HOME/Applications/出海王输入法.app"
TASK_LEGACY_INPUT_TARGET="$HOME/Library/Input Methods/出海王输入法键盘.app"
TASK_LEGACY_APP_TARGET="$HOME/Applications/海王输入法.app"
TASK_PREVIOUS_INPUT_TARGET="$TASK_INPUT_TARGET"
TASK_PREVIOUS_APP_TARGET="$TASK_APP_TARGET"
if [[ ! -e "$TASK_INPUT_TARGET" && -e "$TASK_LEGACY_INPUT_TARGET" ]]; then TASK_PREVIOUS_INPUT_TARGET="$TASK_LEGACY_INPUT_TARGET"; fi
if [[ ! -e "$TASK_APP_TARGET" && -e "$TASK_LEGACY_APP_TARGET" ]]; then TASK_PREVIOUS_APP_TARGET="$TASK_LEGACY_APP_TARGET"; fi
TASK_BACKUP_ROOT="${HAIWANG_BACKUP_ROOT:-$HOME/Library/Developer/Haiwang/InstallBackups}"
TASK_BUNDLE_ID="com.haiwang.inputmethod.Haiwang"

validate_app() {
  local bundle_path="$1" expected_id="$2"
  [[ -d "$bundle_path" ]] || { echo "缺少构建包：$bundle_path。请先构建 macOS 版。" >&2; return 1; }
  local actual_id
  actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle_path/Contents/Info.plist")
  [[ "$actual_id" == "$expected_id" ]] || { echo "包标识不匹配，拒绝替换：$bundle_path" >&2; return 1; }
  codesign --verify --deep --strict "$bundle_path"
}

validate_app "$TASK_INPUT_SOURCE" "$TASK_BUNDLE_ID"
if [[ "$TASK_INPUT_ONLY" != true ]]; then validate_app "$TASK_APP_SOURCE" "com.haiwang.app"; fi
[[ -x "$TASK_TOOL" ]] || { echo "缺少输入源注册工具，请重新构建。" >&2; exit 1; }
codesign --verify --strict "$TASK_TOOL"
for TASK_EXISTING_INPUT in "$TASK_INPUT_TARGET" "$TASK_LEGACY_INPUT_TARGET"; do
  if [[ -e "$TASK_EXISTING_INPUT" ]]; then validate_app "$TASK_EXISTING_INPUT" "$TASK_BUNDLE_ID"; fi
done
if [[ "$TASK_INPUT_ONLY" != true ]]; then
  for TASK_EXISTING_APP in "$TASK_APP_TARGET" "$TASK_LEGACY_APP_TARGET"; do
    if [[ -e "$TASK_EXISTING_APP" ]]; then validate_app "$TASK_EXISTING_APP" "com.haiwang.app"; fi
  done
fi
mkdir -p "$TASK_BACKUP_ROOT" "$HOME/Library/Input Methods" "$HOME/Applications"
TASK_BACKUP=$(mktemp -d "$TASK_BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
TASK_CURRENT="$TASK_BACKUP/selected-input-source.json"
"$TASK_TOOL" snapshot "$TASK_CURRENT" > "$TASK_BACKUP/selected-input-source-readback.json"
"$TASK_TOOL" list --all --bundle haiwang > "$TASK_BACKUP/haiwang-input-sources-before.json"
TASK_STAGE="$TASK_BACKUP/Incoming"
mkdir "$TASK_STAGE"
ditto --noextattr --norsrc --noqtn "$TASK_INPUT_SOURCE" "$TASK_STAGE/出海王输入法键盘.app"
validate_app "$TASK_STAGE/出海王输入法键盘.app" "$TASK_BUNDLE_ID"
if [[ "$TASK_INPUT_ONLY" != true ]]; then
  ditto --noextattr --norsrc --noqtn "$TASK_APP_SOURCE" "$TASK_STAGE/出海王输入法.app"
  validate_app "$TASK_STAGE/出海王输入法.app" "com.haiwang.app"
fi
TASK_NEW_APP=false
TASK_NEW_INPUT=false

rollback() {
  local failure_status=$?
  trap - ERR
  set +e
  if [[ "$TASK_NEW_INPUT" == true && -e "$TASK_INPUT_TARGET" ]]; then
    mv "$TASK_INPUT_TARGET" "$TASK_BACKUP/FailedInputMethod.app"
  fi
  if [[ "$TASK_NEW_APP" == true && -e "$TASK_APP_TARGET" ]]; then
    mv "$TASK_APP_TARGET" "$TASK_BACKUP/FailedMainApp.app"
  fi
  if [[ -e "$TASK_BACKUP/PreviousInputMethod.app" ]]; then
    mv "$TASK_BACKUP/PreviousInputMethod.app" "$TASK_PREVIOUS_INPUT_TARGET"
    "$TASK_TOOL" register "$TASK_PREVIOUS_INPUT_TARGET" > "$TASK_BACKUP/rollback-input-registration.json"
  fi
  if [[ -e "$TASK_BACKUP/PreviousMainApp.app" ]]; then
    mv "$TASK_BACKUP/PreviousMainApp.app" "$TASK_PREVIOUS_APP_TARGET"
  fi
  if [[ -e "$TASK_BACKUP/LegacyNamedInputMethod.app" ]]; then mv "$TASK_BACKUP/LegacyNamedInputMethod.app" "$TASK_LEGACY_INPUT_TARGET"; fi
  if [[ -e "$TASK_BACKUP/LegacyNamedMainApp.app" ]]; then mv "$TASK_BACKUP/LegacyNamedMainApp.app" "$TASK_LEGACY_APP_TARGET"; fi
  if [[ "$TASK_INPUT_ONLY" != true && -e "$TASK_PREVIOUS_APP_TARGET" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TASK_PREVIOUS_APP_TARGET"
  fi
  "$TASK_TOOL" restore-enablement "$TASK_BACKUP/haiwang-input-sources-before.json" > "$TASK_BACKUP/rollback-enabled-input-sources.json"
  "$TASK_TOOL" restore "$TASK_CURRENT" > "$TASK_BACKUP/rollback-selected-input-source.json"
  echo "安装未完成，已尝试恢复原版本及原输入源。所有恢复材料保留于：$TASK_BACKUP" >&2
  exit "$failure_status"
}
trap rollback ERR

# Switching away before stopping an active input method prevents macOS from
# relaunching its old executable while the bundle is being replaced.
TASK_SELECTED_ID=$(/usr/bin/plutil -extract id raw -o - "$TASK_CURRENT")
if [[ "$TASK_SELECTED_ID" == "$TASK_BUNDLE_ID"* ]]; then
  "$TASK_TOOL" list --all > "$TASK_BACKUP/available-input-sources.json"
  TASK_FALLBACK_SELECTED=false
  TASK_FALLBACK_INDEX=0
  while TASK_FALLBACK_ID=$(/usr/bin/plutil -extract "$TASK_FALLBACK_INDEX.id" raw -o - "$TASK_BACKUP/available-input-sources.json" 2>/dev/null); do
    TASK_FALLBACK_ENABLED=$(/usr/bin/plutil -extract "$TASK_FALLBACK_INDEX.enabled" raw -o - "$TASK_BACKUP/available-input-sources.json")
    TASK_FALLBACK_CAPABLE=$(/usr/bin/plutil -extract "$TASK_FALLBACK_INDEX.selectCapable" raw -o - "$TASK_BACKUP/available-input-sources.json")
    if [[ "$TASK_FALLBACK_ID" != "$TASK_BUNDLE_ID"* && "$TASK_FALLBACK_ENABLED" == true && "$TASK_FALLBACK_CAPABLE" == true ]]; then
      if "$TASK_TOOL" select "$TASK_FALLBACK_ID" > "$TASK_BACKUP/temporary-input-source.json" 2> "$TASK_BACKUP/temporary-input-source-error.log"; then
        TASK_FALLBACK_SELECTED=true
        break
      fi
    fi
    TASK_FALLBACK_INDEX=$((TASK_FALLBACK_INDEX + 1))
  done
  if [[ "$TASK_FALLBACK_SELECTED" != true ]]; then
    echo "暂时无法切出出海王输入法；旧版文件尚未替换。" >&2
    false
  fi
fi

stop_installed_app() {
  local bundle_path="$1" executable_name expected_path process_id running_path stop_deadline
  [[ -d "$bundle_path" ]] || return 0
  executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle_path/Contents/Info.plist")
  expected_path="$bundle_path/Contents/MacOS/$executable_name"
  for process_id in $(pgrep -u "$(id -u)" -x "$executable_name" || true); do
    running_path=$(ps -p "$process_id" -ww -o comm= || true)
    [[ "$running_path" == "$expected_path" ]] || continue
    kill -TERM "$process_id"
    stop_deadline=$((SECONDS + 5))
    while kill -0 "$process_id" 2>/dev/null; do
      if [[ $SECONDS -ge $stop_deadline ]]; then
        echo "等待旧版退出超时，尚未替换：$bundle_path" >&2
        return 1
      fi
      sleep 0.1
    done
  done
}

# Replacing files alone leaves the old application running in memory. Stop only
# the exact installed executable, not similarly named builds or other software.
if [[ "$TASK_INPUT_ONLY" != true ]]; then
  stop_installed_app "$TASK_APP_TARGET"
  stop_installed_app "$TASK_LEGACY_APP_TARGET"
fi
stop_installed_app "$TASK_INPUT_TARGET"
stop_installed_app "$TASK_LEGACY_INPUT_TARGET"

# Moves preserve the complete previous bundles, including their metadata. No preferences,
# language packages, learned words or unrelated input sources are removed or replaced.
if [[ -e "$TASK_PREVIOUS_INPUT_TARGET" ]]; then mv "$TASK_PREVIOUS_INPUT_TARGET" "$TASK_BACKUP/PreviousInputMethod.app"; fi
if [[ -e "$TASK_LEGACY_INPUT_TARGET" ]]; then mv "$TASK_LEGACY_INPUT_TARGET" "$TASK_BACKUP/LegacyNamedInputMethod.app"; fi
if [[ "$TASK_INPUT_ONLY" != true ]]; then
  if [[ -e "$TASK_PREVIOUS_APP_TARGET" ]]; then mv "$TASK_PREVIOUS_APP_TARGET" "$TASK_BACKUP/PreviousMainApp.app"; fi
  if [[ -e "$TASK_LEGACY_APP_TARGET" ]]; then mv "$TASK_LEGACY_APP_TARGET" "$TASK_BACKUP/LegacyNamedMainApp.app"; fi
fi
# Retire old names in Launch Services while preserving the complete bundles in the backup.
TASK_OLD_PATHS=("$TASK_LEGACY_INPUT_TARGET")
if [[ "$TASK_INPUT_ONLY" != true ]]; then TASK_OLD_PATHS+=("$TASK_LEGACY_APP_TARGET"); fi
for TASK_OLD_PATH in "${TASK_OLD_PATHS[@]}"; do
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TASK_OLD_PATH" || true
done
mv "$TASK_STAGE/出海王输入法键盘.app" "$TASK_INPUT_TARGET"
TASK_NEW_INPUT=true
validate_app "$TASK_INPUT_TARGET" "$TASK_BUNDLE_ID"
if [[ "$TASK_INPUT_ONLY" != true ]]; then
  mv "$TASK_STAGE/出海王输入法.app" "$TASK_APP_TARGET"
  TASK_NEW_APP=true
  validate_app "$TASK_APP_TARGET" "com.haiwang.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TASK_APP_TARGET"
fi
# A private embedded copy is installation payload, not a second launchable keyboard.
# Prefer the stable installed path over payload/build copies in Launch Services.
if [[ "$TASK_INPUT_SOURCE" == */Contents/Library/InputMethodInstaller/出海王输入法键盘.app ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TASK_INPUT_SOURCE" > "$TASK_BACKUP/payload-unregistration.log" 2>&1 || true
fi
if [[ "$TASK_INPUT_ONLY" != true ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TASK_APP_TARGET/Contents/Library/InputMethodInstaller/出海王输入法键盘.app" > "$TASK_BACKUP/installed-payload-unregistration.log" 2>&1 || true
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TASK_INPUT_TARGET"
"$TASK_TOOL" register "$TASK_INPUT_TARGET" > "$TASK_BACKUP/registration.json"
# Mode defaults alone do not prove the parent was added to the user's keyboard list.
# First installation can require the System Settings add action even after these calls.
if ! "$TASK_TOOL" enable haiwang > "$TASK_BACKUP/unified-enabled.json" 2> "$TASK_BACKUP/unified-enable-error.log"; then
  echo "出海王输入法尚待系统设置添加；文件安装继续，启用尝试已记录。"
fi
if ! "$TASK_TOOL" retire-english > "$TASK_BACKUP/english-retired.json" 2> "$TASK_BACKUP/english-retire-error.log"; then
  echo "旧英文输入源尚待在系统设置中移除；已记录实际状态。"
fi
# Restore even if registration/enablement happens to alter the active system source.
"$TASK_TOOL" restore "$TASK_CURRENT" > "$TASK_BACKUP/selected-input-source-after.json"
"$TASK_TOOL" list --all --bundle haiwang > "$TASK_BACKUP/haiwang-input-sources-after.json"
TASK_PARENT_ENABLED=false
TASK_UNIFIED_ENABLED=false
TASK_ENGLISH_ENABLED=false
TASK_STATUS_INDEX=0
while TASK_STATUS_ID=$(/usr/bin/plutil -extract "$TASK_STATUS_INDEX.id" raw -o - "$TASK_BACKUP/haiwang-input-sources-after.json" 2>/dev/null); do
  TASK_STATUS_ENABLED=$(/usr/bin/plutil -extract "$TASK_STATUS_INDEX.enabled" raw -o - "$TASK_BACKUP/haiwang-input-sources-after.json")
  case "$TASK_STATUS_ID" in
    "$TASK_BUNDLE_ID") TASK_PARENT_ENABLED="$TASK_STATUS_ENABLED" ;;
    "$TASK_BUNDLE_ID.pinyin") TASK_UNIFIED_ENABLED="$TASK_STATUS_ENABLED" ;;
    "$TASK_BUNDLE_ID.english") TASK_ENGLISH_ENABLED="$TASK_STATUS_ENABLED" ;;
  esac
  TASK_STATUS_INDEX=$((TASK_STATUS_INDEX + 1))
done
trap - ERR
rmdir "$TASK_STAGE"
echo "当前输入源已保留；旧版及输入源快照：$TASK_BACKUP"
echo "测试后恢复原输入源：\"$TASK_TOOL\" restore \"$TASK_CURRENT\""
if [[ "$TASK_PARENT_ENABLED" != true || "$TASK_UNIFIED_ENABLED" != true || "$TASK_ENGLISH_ENABLED" == true ]]; then
  printf '%s\n' needs_system_edit > "$TASK_BACKUP/install-status.txt"
  echo "App 和输入法文件已安装并注册；系统键盘列表尚需调整。"
  if [[ "$TASK_PARENT_ENABLED" != true || "$TASK_UNIFIED_ENABLED" != true ]]; then
    echo "  系统设置 → 键盘 → 文本输入 → 编辑 → ＋ → 简体中文 → 出海王输入法 → 添加。"
  fi
  if [[ "$TASK_ENGLISH_ENABLED" == true ]]; then
    echo "  系统设置 → 键盘 → 文本输入 → 编辑 → 选中海王·英文 → −。"
  fi
  echo "出海王输入法同时支持拼音和英文；选中后轻按 Shift 切换中英文。"
  echo "真实系统状态保存在：$TASK_BACKUP/haiwang-input-sources-after.json"
  if [[ "$TASK_OPEN" == true ]]; then
    open 'x-apple.systempreferences:com.apple.Keyboard-Settings.extension' || true
    open "$TASK_APP_TARGET"
  fi
  # Files are installed and backed up. Exit 2 means a system keyboard edit is pending.
  exit 2
fi
printf '%s\n' ready > "$TASK_BACKUP/install-status.txt"
echo "系统已确认单一出海王输入源已启用，独立英文输入源已移除。选中出海王后轻按 Shift 切换中英文。"
if [[ "$TASK_OPEN" == true ]]; then open "$TASK_APP_TARGET"; fi

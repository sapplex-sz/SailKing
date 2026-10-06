#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_BASE="$HOME/Library/Developer/Haiwang/CandidatePanelSmoke"
mkdir -p "$TASK_BASE"
TASK_RUN=$(mktemp -d "$TASK_BASE/run.XXXXXX")
TASK_APP="$TASK_RUN/CandidatePanelPreview.app"
TASK_CONTENTS="$TASK_APP/Contents"
mkdir -p "$TASK_CONTENTS/MacOS" "$TASK_CONTENTS/Resources" "$TASK_CONTENTS/Frameworks" "$TASK_RUN/modules"
cat > "$TASK_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.haiwang.tests.CandidatePanelPreview</string>
<key>CFBundleName</key><string>CandidatePanelPreview</string>
<key>CFBundleExecutable</key><string>CandidatePanelPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp "$TASK_ROOT/macOS/InputMethod/Resources/"*.tiff "$TASK_CONTENTS/Resources/"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" -parse-as-library \
  -emit-library -emit-module -module-name HaiwangCore \
  -emit-module-path "$TASK_RUN/modules/HaiwangCore.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/libHaiwangCore.dylib' \
  "$TASK_ROOT"/Sources/HaiwangCore/*.swift -o "$TASK_CONTENTS/Frameworks/libHaiwangCore.dylib"
xcrun swiftc -D DEBUG -swift-version 5 -target "$(uname -m)-apple-macosx26.0" -parse-as-library \
  -I "$TASK_RUN/modules" -L "$TASK_CONTENTS/Frameworks" -lHaiwangCore \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "$TASK_ROOT/macOS/InputMethod/CandidatePanel.swift" "$TASK_ROOT/Tests/CandidatePanelSmoke/main.swift" \
  -o "$TASK_CONTENTS/MacOS/CandidatePanelPreview" > "$TASK_RUN/compile.log" 2>&1 || {
  tail -70 "$TASK_RUN/compile.log"
  exit 1
}
xattr -cr "$TASK_APP"
codesign --force --deep --sign - "$TASK_APP"
echo "Panel test artifacts: $TASK_RUN"
"$TASK_CONTENTS/MacOS/CandidatePanelPreview" --test "$TASK_RUN"
echo "Native drag preview: $TASK_APP"

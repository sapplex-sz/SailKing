#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_BASE="$HOME/Library/Developer/Haiwang/OnboardingSmoke"
mkdir -p "$TASK_BASE"
TASK_RUN=$(mktemp -d "$TASK_BASE/run.XXXXXX")
TASK_APP="$TASK_RUN/OnboardingPreview.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_APP/Contents/Frameworks" "$TASK_RUN/modules"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.haiwang.tests.OnboardingPreview</string>
<key>CFBundleExecutable</key><string>OnboardingPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp "$TASK_ROOT/macOS/Resources/HaiwangBrand.png" "$TASK_APP/Contents/Resources/"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" -parse-as-library \
  -emit-library -emit-module -module-name HaiwangCore -emit-module-path "$TASK_RUN/modules/HaiwangCore.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/libHaiwangCore.dylib' \
  "$TASK_ROOT"/Sources/HaiwangCore/*.swift -o "$TASK_APP/Contents/Frameworks/libHaiwangCore.dylib"
xcrun swiftc -D DEBUG -swift-version 5 -target "$(uname -m)-apple-macosx26.0" -parse-as-library \
  -I "$TASK_RUN/modules" -L "$TASK_APP/Contents/Frameworks" -lHaiwangCore \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "$TASK_ROOT"/SharedUI/*.swift "$TASK_ROOT"/SharedRuntime/*.swift "$TASK_ROOT/Tests/OnboardingSmoke/main.swift" \
  -o "$TASK_APP/Contents/MacOS/OnboardingPreview" > "$TASK_RUN/compile.log" 2>&1 || {
    tail -50 "$TASK_RUN/compile.log"
    exit 1
  }
xattr -cr "$TASK_APP"
codesign --force --deep --sign - "$TASK_APP"
"$TASK_APP/Contents/MacOS/OnboardingPreview" "$TASK_RUN" -AppleLanguages '(zh-Hans)'
"$TASK_APP/Contents/MacOS/OnboardingPreview" "$TASK_RUN" -AppleLanguages '(en)'
echo "Onboarding fixture artifacts: $TASK_RUN"

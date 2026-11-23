#!/bin/bash
# build.sh — 编译 cme-uf8-router 菜单栏 App(本地,无外部依赖)
# 产物:build/cme-uf8-router.app (universal2: x86_64 + arm64, ad-hoc 签名)
# 用法:bash build.sh
# 说明:双架构 => Intel 与 Apple Silicon (M 系列) 都能运行。

set -e
cd "$(dirname "$0")"

APP="build/cme-uf8-router.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "==> 清理旧产物"
rm -rf build/ && mkdir -p build/clang-module-cache "$MACOS"

echo "==> 编译源码 (x86_64 + arm64 → universal2)"
SRCS=(
  src/main.m
  src/AppDelegate.m
  src/RouterCore.m
  src/CMEMIDIProtocol.m
  src/MIDIMapper.m
)

FRAMEWORKS=""
for fw in Cocoa CoreMIDI CoreFoundation IOKit Foundation; do
  FRAMEWORKS="$FRAMEWORKS -framework $fw"
done

clang -fobjc-arc -fmodules \
  -fmodules-cache-path="build/clang-module-cache" \
  -arch x86_64 -arch arm64 \
  -O2 \
  -Wno-poison-system-directories \
  -Wno-direct-ivar-access \
  -Wno-objc-missing-super-calls \
  -Wno-declaration-after-statement \
  ${SRCS[@]} \
  $FRAMEWORKS \
  -o "$MACOS/cme-uf8-router"

echo "==> 架构检查(应为 universal: x86_64 + arm64)"
file "$MACOS/cme-uf8-router"
lipo -info "$MACOS/cme-uf8-router"

echo "==> ad-hoc 签名(arm64 必须,否则 M 芯片拒绝运行)"
codesign --force -s - "$MACOS/cme-uf8-router" 2>&1
codesign -dv "$MACOS/cme-uf8-router" 2>&1 | head -3

echo "==> 拷贝图标资源"
mkdir -p "$CONTENTS/Resources"
cp resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
cp resources/menubar.png "$CONTENTS/Resources/menubar.png"
cp resources/menubar@2x.png "$CONTENTS/Resources/menubar@2x.png"

echo "==> 写 Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>cme-uf8-router</string>
    <key>CFBundleIdentifier</key>
    <string>local.cmeuf8.router</string>
    <key>CFBundleName</key>
    <string>cme-uf8-router</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.8</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>cme-uf8-router 0.1.8</string>
</dict>
</plist>
PLIST

echo "==> 整个 .app 再签一次(含 Resources)"
codesign --force -s - "$APP" 2>&1
codesign -dv "$APP" 2>&1 | head -3

echo "==> 自检(协议层)"
"$MACOS/cme-uf8-router" --selftest

echo "==> 完成: $APP"
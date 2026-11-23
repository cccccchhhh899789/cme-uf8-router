#!/bin/bash
# make-dmg.sh — 打包 cme-uf8-router 为可分发的 DMG
# 产物:release/cme-uf8-router-v0.1.0.dmg (内含 .app + 使用说明)
# 用法:bash make-dmg.sh
# 说明:DMG 在 /tmp 生成(需 HFS+)再移到工作区,避免 ExFAT 不支持。

set -e
cd "$(dirname "$0")"
VERSION="0.1.10"

echo "==> 1/4 编译"
bash build.sh > /tmp/build.log 2>&1 || { echo "编译失败,见 /tmp/build.log"; exit 1; }

echo "==> 2/4 组装 staging"
STAGE="/tmp/cme-uf8-router-dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R build/cme-uf8-router.app "$STAGE/"
# 附使用说明(若无则生成简版)
if [ ! -f 使用说明.txt ]; then cp 使用说明模板.txt "$STAGE/使用说明.txt" 2>/dev/null || true; fi
cp 使用说明.txt "$STAGE/" 2>/dev/null || echo "（未找到使用说明，将不放）" 

echo "==> 3/4 生成 DMG"
mkdir -p release
rm -f "release/cme-uf8-router-v${VERSION}.dmg"
# 先输出到 /tmp(避免目录冲突),成功后再移到工作区 release/
TMPDMG="/tmp/cme-uf8-router-v${VERSION}.dmg"
rm -f "$TMPDMG"
hdiutil create -volname "cme-uf8-router" \
  -srcfolder "$STAGE" \
  -ov \
  "$TMPDMG" > /tmp/hdiutil.log 2>&1
mv "$TMPDMG" "release/cme-uf8-router-v${VERSION}.dmg"
echo "DMG 生成: $(ls -lh release/cme-uf8-router-v${VERSION}.dmg | awk '{print $5, $9}')"

echo "==> 4/4 清理"
rm -rf "$STAGE"
echo "完成: release/cme-uf8-router-v${VERSION}.dmg"
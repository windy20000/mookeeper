#!/bin/bash
# 把 build/MooKeeper.app 打成可双击安装的 PKG（默认未签名）。
#
# 用法：./build.sh && ./scripts/make_pkg.sh
#
# 产出的 build/MooKeeper-<版本>.pkg 会：装 App 到 /Applications、清隔离属性、按登录用户
# 铺示例配置/音效、注册登录自启、装完启动（细节见 scripts/pkg/postinstall）。
#
# ⚠️ 未签名的 PKG 经**浏览器**下载后带 com.apple.quarantine → 双击被 Gatekeeper 直接判「程序已损坏」
#    （macOS 15+ 对 unsigned pkg 没有「仍要打开」入口，spctl 实测 rejected/no usable signature）：
#    解法一 `xattr -d com.apple.quarantine <pkg>` 后双击，解法二 `sudo installer -pkg <pkg> -target /`
#    （installer 入口不跑 Gatekeeper 评估，两者 postinstall 均正常）；终端 `curl -O` 下载不带隔离属性，双击即装。
#    要做到「陌生人下载即双击」，必须有 Developer ID Installer 证书签名 + 公证：
#      MOOKEEPER_INSTALLER_ID="Developer ID Installer: 你的名字 (TEAMID)" ./scripts/make_pkg.sh
#      xcrun notarytool submit build/MooKeeper-<版本>.pkg --keychain-profile <配置名> --wait
#      xcrun stapler staple build/MooKeeper-<版本>.pkg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MooKeeper.app"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
ID="com.windy20000.mookeeper.pkg"
STAGE="$BUILD/pkg-stage"
COMP="$BUILD/pkg-component"
RES="$BUILD/pkg-res"
SCRIPTS="$BUILD/pkg-scripts"
DIST="$BUILD/pkg-distribution.xml"
PKG="$BUILD/MooKeeper-$VER.pkg"

[ -x "$APP/Contents/MacOS/mookeeper" ] || { echo "✗ 还没构建：先执行 ./build.sh"; exit 1; }
command -v pkgbuild >/dev/null || { echo "✗ 缺 pkgbuild（属于 Xcode Command Line Tools）"; exit 1; }

echo "→ 准备 payload / 脚本 / 资源"
rm -rf "$STAGE" "$COMP" "$RES" "$SCRIPTS"
mkdir -p "$STAGE/Applications" "$COMP" "$RES" "$SCRIPTS"
ditto "$APP" "$STAGE/Applications/MooKeeper.app"
# 源码树若从 Keka/浏览器解压而来会带隔离属性，这里清干净再做包（postinstall 里还有一道兜底）
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
install -m 755 "$ROOT/scripts/pkg/postinstall" "$SCRIPTS/postinstall"
install -m 644 "$ROOT/scripts/pkg/welcome.txt" "$RES/welcome.txt"
install -m 644 "$ROOT/LICENSE" "$RES/LICENSE.txt"

echo "→ 组件包（pkgbuild）"
pkgbuild --root "$STAGE" --install-location / \
  --identifier "$ID" --version "$VER" \
  --ownership recommended \
  --scripts "$SCRIPTS" "$COMP/MooKeeper.pkg"

echo "→ 产品包（productbuild：标题 / 欢迎页 / 许可页）"
cat >"$DIST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>MooKeeper $VER</title>
  <organization>com.windy20000</organization>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <options customize="never" require-scripts="false"/>
  <welcome file="welcome.txt" mime-type="text/plain"/>
  <license file="LICENSE.txt" mime-type="text/plain"/>
  <choices-outline>
    <line choice="default">
      <line choice="$ID"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="$ID" visible="false">
    <pkg-ref id="$ID"/>
  </choice>
  <pkg-ref id="$ID" version="$VER" onConclusion="none">MooKeeper.pkg</pkg-ref>
</installer-gui-script>
EOF
rm -f "$PKG"
productbuild --distribution "$DIST" --resources "$RES" --package-path "$COMP" "$PKG"

if [ -n "${MOOKEEPER_INSTALLER_ID:-}" ]; then
  echo "→ Developer ID 签名（${MOOKEEPER_INSTALLER_ID}）"
  productsign --sign "$MOOKEEPER_INSTALLER_ID" "$PKG" "$PKG.signed"
  mv "$PKG.signed" "$PKG"
else
  echo "ℹ️ 未签名 —— 浏览器下载的包会被 Gatekeeper 判「已损坏」（无「仍要打开」可绕）：先 xattr -d com.apple.quarantine <pkg> 再双击，或 sudo installer -pkg <pkg> -target /"
  echo "   要免掉它：MOOKEEPER_INSTALLER_ID=\"Developer ID Installer: …\" 重跑本脚本 + 公证"
fi

echo "✅ PKG：$PKG"
ls -lh "$PKG" | awk '{print "   大小："$5}'
echo "   自检：pkgutil --check-signature \"$PKG\" | head -3"
echo "   安装：open \"$PKG\"（或 sudo installer -pkg \"$PKG\" -target /）"
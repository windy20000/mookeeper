#!/bin/bash
# MooKeeper 原生版构建脚本（CLT-only，无 Xcode/SwiftPM；SMC 用 clang，Swift 用 swiftc）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"                       # arm64 / x86_64，自动适配
MINVER="14.0"
TARGET="$ARCH-apple-macosx$MINVER"
APP="$BUILD/MooKeeper.app"
mkdir -p "$BUILD/.modcache" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ 编译 SMC.c"
clang -isysroot "$SDK" -mmacosx-version-min="$MINVER" -O2 -Wall -Wextra \
  -c "$ROOT/Sources/SMC.c" -o "$BUILD/SMC.o"

echo "→ 编译 Swift（Sources/*.swift）"
SOURCES=("$ROOT"/Sources/*.swift)
TMPDIR="$BUILD/.modcache" swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" \
  -import-objc-header "$ROOT/Sources/SMC.h" \
  "${SOURCES[@]}" "$BUILD/SMC.o" \
  -framework AppKit -framework SwiftUI -framework IOKit -framework UserNotifications \
  -module-cache-path "$BUILD/.modcache" \
  -o "$APP/Contents/MacOS/mookeeper"

echo "→ 图标（make_icon.swift + iconutil）"
if [ -f "$ROOT/scripts/make_icon.swift" ]; then
  TMPDIR="$BUILD/.modcache" swiftc -swift-version 5 -sdk "$SDK" -target "$TARGET" \
    "$ROOT/scripts/make_icon.swift" -framework AppKit -framework SwiftUI -module-cache-path "$BUILD/.modcache" -o "$BUILD/make_icon"

  build_icns() {  # $1=变体(plain/dark/light)  $2=输出 icns 文件名
    "$BUILD/make_icon" "$BUILD/AppIcon-$1-1024.png" "$1" >/dev/null
    rm -rf "$BUILD/AppIcon.iconset"; mkdir -p "$BUILD/AppIcon.iconset"
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$BUILD/AppIcon-$1-1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
      d=$((s*2))
      sips -z "$d" "$d" "$BUILD/AppIcon-$1-1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/$2"
  }

  build_icns plain AppIcon.icns          # 透明底贴纸（定稿默认）
  build_icns dark  AppIcon-Dark.icns     # 深色模式变体（深炭 tile）
  build_icns light AppIcon-Light.icns    # 浅色模式变体（白 tile）

  # 菜单里的「看门牛」小徽章（白天/晚上两版，随系统外观切换）
  "$BUILD/make_icon" "$APP/Contents/Resources/MenuLogo-Light.png" menu-light >/dev/null
  "$BUILD/make_icon" "$APP/Contents/Resources/MenuLogo-Dark.png"  menu-dark  >/dev/null
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD/AppIcon-Dark.icns" "$APP/Contents/Resources/AppIcon-Dark.icns"
cp "$BUILD/AppIcon-Light.icns" "$APP/Contents/Resources/AppIcon-Light.icns"

echo "→ Info.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "→ 打包示例配置（源在 docs/，bundle 资源名不变——Config.swift 按名取）"
cp "$ROOT/docs/config.example.json" "$APP/Contents/Resources/config.example.json"
cp "$ROOT/docs/config.example.zh.json" "$APP/Contents/Resources/config.example.zh.json"   # 中文系统用 zh 版（exampleConfigURL 选版）

echo "→ 打包品牌音效"
if [ -f "$ROOT/Resources/moo.aiff" ]; then
  # macOS 解析通知自定义音：文件必须在 Resources **根目录**（Resources/Sounds 之类的子目录无效，实测），
  # 且代码里引用名不带扩展名（见 Notify.swift 的 mooSoundRefName）。别把这里挪进子目录。
  cp "$ROOT/Resources/moo.aiff" "$APP/Contents/Resources/moo.aiff"
else
  echo "⚠️ 缺 Resources/moo.aiff，提示音将回落系统默认"
fi

echo "→ 清除隔离属性（必须先于签名）"
# 源码树若由 Keka/浏览器解压而来会带 com.apple.quarantine，上面几条 cp 会把它复制进 bundle；
# LaunchServices 一评估就弹「Apple 无法验证 MooKeeper …」（ad-hoc 签名无 Developer ID，必被拒）。
# 只删隔离属性、不动 com.apple.provenance；xattr 不属于签名封存内容，放签名前更干净。
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "→ ad-hoc 签名"
codesign --force --sign - "$APP"

echo "✅ 构建完成：$APP"
#!/bin/bash
# 安装到 ~/Applications 并（可选）注册登录自启
# 用法：./install.sh [--autostart]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/MooKeeper.app"
DEST="$HOME/Applications/MooKeeper.app"
AUTOSTART=0
[ "${1:-}" = "--autostart" ] && AUTOSTART=1

[ -x "$APP/Contents/MacOS/mookeeper" ] || { echo "未构建，先跑 build.sh"; exit 1; }

echo "→ 停止旧实例（若有）"
pkill -x mookeeper 2>/dev/null || true
sleep 1   # 等旧实例优雅退出，避免紧随的 open 误判「已在运行」而只激活不换代码

echo "→ 安装到 $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
# cp -R 会把源码/构建产物上的 com.apple.quarantine 一起带过来（Keka 解压的树必带），
# 结果就是「Apple 无法验证 MooKeeper …」——安装后立刻清掉，再签名。
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --sign - "$DEST" 2>/dev/null || true

if [ "$AUTOSTART" = 1 ]; then
  PLIST="$HOME/Library/LaunchAgents/com.windy20000.mookeeper.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.windy20000.mookeeper</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/open</string><string>$HOME/Applications/MooKeeper.app</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
  # macOS 26+ 弃用了 launchctl load/unload，改用 bootstrap/bootout（gui/<uid> 域）
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    echo "→ 已注册登录自启（${PLIST}）"
  else
    echo "⚠️ 自启注册失败（多半在非 GUI 会话里跑脚本；请到桌面终端里再跑一次 ./install.sh --autostart）"
  fi
fi

echo "→ 示例配置（中/英两版）到 ~/.config/mookeeper/（不覆盖你的 config.json）"
mkdir -p "$HOME/.config/mookeeper"
cp "$ROOT/docs/config.example.json" "$HOME/.config/mookeeper/config.example.json"
cp "$ROOT/docs/config.example.zh.json" "$HOME/.config/mookeeper/config.example.zh.json"
xattr -dr com.apple.quarantine "$HOME/.config/mookeeper" 2>/dev/null || true

echo "→ 品牌音效注册到 ~/Library/Sounds（系统按名解析；也让你能在系统设置里选它）"
if [ -f "$ROOT/Resources/moo.aiff" ]; then
  mkdir -p "$HOME/Library/Sounds"
  cp "$ROOT/Resources/moo.aiff" "$HOME/Library/Sounds/moo.aiff"
  xattr -d com.apple.quarantine "$HOME/Library/Sounds/moo.aiff" 2>/dev/null || true
else
  echo "⚠️ 缺 Resources/moo.aiff，通知提示音会回落系统默认声"
fi

echo "→ 启动"
open "$DEST"
echo "✅ 完成。菜单栏出现「剩余可用 GB」那个数字（绿/橙/红＝内存压力）就是装好了，它 5 秒一拍自己走。"
echo "   点开推开「看门牛农场」：🐏 资源（内存 / SWAP / 存储）· 🚜 计算（CPU / GPU / 负载）· 🐝 风扇 · ☀️ 温度 · 🐎 功率 · 📡/⚡️/🕸️ 网络（↑↓ 流量，图标＝货走的哪条路）"
echo "   往下可一键启停你的服务 / 大模型分组，成败都会弹系统通知（该响的哞一声）；改配置按 ⌘,，想立刻看一眼就点「刷新」行或按 ⌘R。"
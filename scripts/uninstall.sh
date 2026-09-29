#!/bin/bash
# MooKeeper 卸载：停进程、摘掉登录自启、删 App（/Applications 或 ~/Applications 都认）。
# 配置和提示音默认保留（里面有你自己写的命令），要一起删就 --purge。
set -uo pipefail
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "→ 停进程 / 摘自启"
pkill -x mookeeper 2>/dev/null || true
PLIST="$HOME/Library/LaunchAgents/com.windy20000.mookeeper.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "→ 删 App"
for APP in "/Applications/MooKeeper.app" "$HOME/Applications/MooKeeper.app"; do
  [ -d "$APP" ] || continue
  if [ -w "$(dirname "$APP")" ]; then
    rm -rf "$APP" && echo "   已删 $APP"
  else
    sudo rm -rf "$APP" && echo "   已删 ${APP}（sudo）"
  fi
done

if [ "$PURGE" = 1 ]; then
  echo "→ --purge：连配置与提示音一起删"
  rm -rf "$HOME/.config/mookeeper"
  rm -f "$HOME/Library/Sounds/moo.aiff"
else
  echo "→ 配置 ~/.config/mookeeper 与提示音 ~/Library/Sounds/moo.aiff 保留（--purge 可一并删除）"
fi
echo "✅ 卸载完成"
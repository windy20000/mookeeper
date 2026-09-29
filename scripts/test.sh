#!/bin/bash
# MooKeeper 冒烟测试 runner——开源协作底线：改完跑这个，绿了再提 PR。
#
# 用法：
#   ./scripts/test.sh              # 无头子集（CI 安全档）：build → --gen → --dump(好/坏配置) → --netkind → --notif
#   ./scripts/test.sh --gui        # 追加依赖真实登录 GUI 会话的口：--errtest、--menu-keytest openrefresh
#   ./scripts/test.sh --no-build   # 跳过编译（刚 build 过、只想跑诊断口）
#
# 约定：--errtest / --menu-keytest openrefresh 自带 PASS/FAIL 退出码；其余口由本脚本做最小输出断言。
# 任何一步失败立即退出非 0。GUI 口不进 CI（GitHub macOS runner 的 Aqua 会话不可靠，宁缺毋假绿）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/MooKeeper.app/Contents/MacOS/mookeeper"

GUI=false; NO_BUILD=false
for a in "$@"; do
  case "$a" in
    --gui) GUI=true ;;
    --no-build) NO_BUILD=true ;;
    *) echo "用法：$0 [--gui] [--no-build]" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
pass() { printf '  \033[32mok\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

$NO_BUILD || { say "build.sh"; "$ROOT/build.sh" >/dev/null 2>&1 || fail "编译失败（去掉 --no-build 重跑看完整报错）"; }
[ -x "$BIN" ] || fail "找不到可执行文件 ${BIN}（先 ./build.sh）"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/moo-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ───────────────────────── 无头子集（CI 可跑） ─────────────────────────

say "--gen 粘贴命令解析"
OUT="$("$BIN" --gen "ruby -run -e httpd ~/Public -p 8028 &" 2>&1)" || fail "--gen 非零退出"
case "$OUT" in *"key="*) pass "--gen → ${OUT}";; *) fail "--gen 输出缺 key=：${OUT}";; esac

say "--dump 正常配置（port 条目 + footer）"
cat > "$TMP/good.json" <<'EOF'
{ "topN": 3,
  "groups": [ { "title": "测试组", "items": [
    { "key": "srv", "label": "本地服务", "port": 8123 } ] } ],
  "footer": [ { "label": "探针", "command": "/usr/bin/true" } ] }
EOF
OUT="$(MOOKEEPER_CONFIG="$TMP/good.json" "$BIN" --dump 2>&1)" || fail "--dump 非零退出"
echo "$OUT" | grep -q "测试组" || fail "--dump 缺分组标题"
echo "$OUT" | grep -q "8123"   || fail "--dump 缺端口条目"
pass "--dump 分组/端口条目齐全"

say "--dump 坏配置（port 缺失/topN 越界：不致命、条目不弃、topN 收顶）"
cat > "$TMP/bad.json" <<'EOF'
{ "topN": 999, "groups": [ { "title": "坏组", "items": [
    { "key": "nop", "label": "缺port", "probe": "port" } ] } ] }
EOF
OUT="$(MOOKEEPER_CONFIG="$TMP/bad.json" "$BIN" --dump 2>&1)" || fail "坏配置 --dump 应非致命（rc≠0＝校验把整份拒了，回归）"
echo "$OUT" | grep -q "坏组"   || fail "坏配置里的条目被误弃"
echo "$OUT" | grep -q "TOP 50" || fail "topN 未收顶到 50（Hardwired.topNMax）"
pass "加载校验不误伤，topN 收顶"

say "--netkind 强制判型（免拔线覆盖分支）"
OUT="$("$BIN" --netkind en6 2>&1)" || fail "--netkind 非零退出"
echo "$OUT" | grep -q "netkind:" || fail "--netkind 无输出"
pass "--netkind en6 → $(echo "$OUT" | grep netkind: | head -1)"

say "--notif 通知授权状态可打印"
OUT="$("$BIN" --notif 2>&1)" || fail "--notif 非零退出"
echo "$OUT" | grep -q "NOTIF" || fail "--notif 输出缺 NOTIF 行"
pass "$OUT"

# ───────────────────────── GUI 档（仅本地有登录会话） ─────────────────────────

if $GUI; then
  say "GUI 档准备：收掉在跑的实例（避免双菜单栏与跟踪态干扰）"
  pkill -x mookeeper 2>/dev/null || true
  sleep 0.5

  say "--errtest（错误提醒行全生命周期断言，自带 PASS/FAIL）"
  "$BIN" --errtest || fail "--errtest FAIL（看上方日志分叉定位断在哪）"
  pass "--errtest 全绿"

  say "--menu-keytest openrefresh（悬停残留清除 + menuNeedsUpdate 节流 rebuild）"
  "$BIN" --menu-keytest openrefresh || fail "openrefresh FAIL（判据三个时间数字）"
  pass "--menu-keytest openrefresh 全绿"
fi

printf '\n\033[32m\033[1m✅ 全部通过\033[0m（%s档）\n' "$($GUI && echo 无头+GUI || echo 无头)"

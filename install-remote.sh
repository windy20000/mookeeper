#!/bin/bash
# MooKeeper 一行安装：curl -fsSL https://raw.githubusercontent.com/windy20000/mookeeper/main/install-remote.sh | bash
#
# 等价于 git clone + ./build.sh + ./install.sh，只是替你拉源码、构建、安装，然后清掉临时目录。
# 因为是**本机编译**，产物没有 com.apple.quarantine，不会撞 Gatekeeper（也不需要开发者帐号）。
#
# 源码默认拉**最新 release tag**（不是 main）：上游误推或账号被盗时，未审代码不会直接进你的机器。
# 仓库还没有 tag 时明确报错退出，绝不静默回落 main——宁可不装，不可盲装。
#
# 常用：
#   curl -fsSL <上面的地址> | bash                        # 装最新发布版到 ~/Applications 并启动
#   curl -fsSL <上面的地址> | bash -s -- --autostart      # 顺带注册登录自启
#
# 可覆盖的环境变量：MOOKEEPER_REPO（git 地址）、MOOKEEPER_BRANCH（要装的 ref：只接受 tag 或分支名；
# 裸 commit SHA 不支持——git clone --depth 1 --branch 不认 SHA，需要装某个 commit 请手动 checkout。
# 默认自动取仓库里最新的 v* release tag；设 main 追开发版自担风险）。⚠ MOOKEEPER_REPO 指向别处＝放弃本项目校验，慎用。
set -euo pipefail

REPO="${MOOKEEPER_REPO:-https://github.com/windy20000/mookeeper.git}"
# 只认 v+数字 开头的 release tag，杂名 tag（backup/*、试验串等）不进选版，防污染 sort -V。
LATEST_TAG="$(git ls-remote --tags --refs "$REPO" 2>/dev/null | awk '{print $2}' | grep -E '^refs/tags/v[0-9]' | sed 's|refs/tags/||' | sort -V | tail -1 || true)"
REF="${MOOKEEPER_BRANCH:-$LATEST_TAG}"
if [ -z "$REF" ]; then
  echo "✗ 仓库还没有以 v 开头的 release tag（如 v0.1），无法确定要装哪个版本。"
  echo "  确认要装开发版（main，自担风险）：MOOKEEPER_BRANCH=main 重新执行本脚本。"
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mookeeper-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "🐮 MooKeeper 一行安装（本机编译，不经 Gatekeeper）"

echo "→ 检查 Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
  cat <<'EOS'
✗ 没找到命令行工具。请先执行：

    xcode-select --install

  在弹出的窗口里点「安装」并等它跑完，然后重新执行本脚本。
EOS
  exit 1
fi
echo "   $(xcode-select -p)"

echo "→ 拉源码：${REPO}（ref ${REF}）"
git clone --depth 1 --branch "$REF" "$REPO" "$WORK/src"
cd "$WORK/src"

echo "→ 构建"
./build.sh

echo "→ 安装"
./install.sh "$@"

echo "✅ 完成。菜单栏出现内存数字即成功；临时源码副本已清理。"
echo "   卸载：pkill -x mookeeper && rm -rf ~/Applications/MooKeeper.app"
echo "        （登录自启还想关：rm -f ~/Library/LaunchAgents/com.windy20000.mookeeper.plist）"
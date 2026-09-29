#!/bin/bash
# 生成 Homebrew formula：把 packaging/homebrew/mookeeper.rb.in 里的
# __URL__ / __SHA256__ / __VERSION__ / __URL_KIND__ 填好。
#
# 用法：./scripts/make_formula.sh [ref] [输出文件]
#   ref 默认 v<Info.plist 里的版本>（例：v0.1）；远端没有这个 tag 会自动回落到 main 并警告。
#   输出默认 build/mookeeper.rb —— 复制到你的 tap 仓库的 Formula/ 下即可。
#
# 例：git tag v0.1 && git push origin v0.1 && ./scripts/make_formula.sh v0.1   # 稳定版（推荐，定向推别 --tags）
#     ./scripts/make_formula.sh                                          # tag 还没推时用 main
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="${MOOKEEPER_REPO_SLUG:-windy20000/mookeeper}"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
REF="${1:-v$VER}"
OUT="${2:-$ROOT/build/mookeeper.rb}"
TMPL="$ROOT/packaging/homebrew/mookeeper.rb.in"
[ -f "$TMPL" ] || { echo "✗ 缺模板 $TMPL"; exit 1; }

url_for() {
  case "$1" in
    v[0-9]*) echo "https://github.com/$SLUG/archive/refs/tags/$1.tar.gz" ;;
    *) echo "https://github.com/$SLUG/archive/refs/heads/$1.tar.gz" ;;
  esac
}

TARBALL="$(mktemp -t mookeeper-formula)"
trap 'rm -f "$TARBALL"' EXIT

REF_KIND="tag"
URL="$(url_for "$REF")"
if ! curl -fsSL --retry 2 "$URL" -o "$TARBALL"; then
  if [ "$REF" = "main" ]; then
    echo "✗ 下载失败：$URL" >&2
    exit 1
  fi
  echo "⚠️ 远端没有 ${REF}，回落到 main 分支 —— 注意：main 的 tarball 每次 push 后 sha256 都会变" >&2
  echo "   发布前建议：git tag ${REF} && git push origin ${REF}，再重跑本脚本" >&2
  REF="main"
  REF_KIND="main 分支"
  URL="$(url_for main)"
  curl -fsSL --retry 2 "$URL" -o "$TARBALL"
fi

SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
mkdir -p "$(dirname "$OUT")"
sed -e "s|__URL__|$URL|" \
    -e "s|__SHA256__|$SHA|" \
    -e "s|__VERSION__|$VER|" \
    -e "s|__URL_KIND__|$REF_KIND|" "$TMPL" >"$OUT"

echo "✅ 已生成 $OUT"
echo "   url    = $URL"
echo "   sha256 = $SHA"
echo "→ 装进 tap：cp \"$OUT\" <你 clone 的 homebrew-tap>/Formula/mookeeper.rb && cd <...> && git commit -am 'mookeeper $VER' && git push"
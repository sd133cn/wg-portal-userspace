#!/bin/sh
# 漂移检测：把本仓库 portal/ 与上游 h44z/wg-portal 的某个 ref 逐文件比对。
#
#   sh scripts/check-upstream.sh              # 与 portal/UPSTREAM.md 里钉住的 commit 比对
#   sh scripts/check-upstream.sh master       # 与上游最新 master 比对（看上游有没有新提交）
#   sh scripts/check-upstream.sh v2.3.1       # 与某个 tag 比对
#   UPSTREAM_TARBALL=/tmp/up.tar.gz sh scripts/check-upstream.sh    # 离线：直接用已下载的上游 tarball
#
# 与钉住的 commit 比对时的**预期结果**（见 portal/UPSTREAM.md）：
#   - 「内容不同」只有 1 个：internal/adapters/wgcontroller/local.go（本项目唯一的 userspace 补丁）
#   - 「只在上游有」= 上游的 CI / 部署示例 / 文档等（有意不收录）
#   - 「只在本仓库有」= internal/app/api/core/frontend-dist/（构建时生成，已从比对中剔除）
# 出现别的差异时脚本以退出码 1 结束（= 需要人工看一眼再更新 portal/UPSTREAM.md）。
#
# 依赖：curl 或 wget、tar、find、sed、grep、cmp（POSIX 环境）。
# Windows 用户请在 WSL / Git Bash / 一个 Linux 容器里跑，例如：
#   docker run --rm -v "$PWD:/repo:ro" alpine:3.24 sh /repo/scripts/check-upstream.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTAL="$ROOT/portal"
UPSTREAM_MD="$PORTAL/UPSTREAM.md"

PATCHED="internal/adapters/wgcontroller/local.go"          # 本项目对上游的唯一代码改动
GENERATED="internal/app/api/core/frontend-dist"            # 构建时生成，不参与比对
LOCAL_EXTRA="UPSTREAM.md"                                  # 本文件（上游没有，预期内）
# 上游有、本仓库有意不收录（与 portal/UPSTREAM.md 的表格一一对应）
EXCLUDE_RE='^(\.github|\.run|deploy|docs|scripts)/|^(docker-compose\.yml|ct\.yaml|Makefile|mkdocs\.yml|wg-portal-linux-amd64)$'

[ -f "$UPSTREAM_MD" ] || { echo "找不到 $UPSTREAM_MD" >&2; exit 2; }
read_md() { sed -n "s/^$1:[[:space:]]*//p" "$UPSTREAM_MD" | head -1; }

REPO="${UPSTREAM_REPO:-$(read_md upstream_repo)}"
PINNED="$(read_md upstream_ref)"
REF="${1:-$PINNED}"
[ -n "$REPO" ] && [ -n "$REF" ] || { echo "无法从 $UPSTREAM_MD 解析 upstream_repo / upstream_ref" >&2; exit 2; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t upcheck)"
trap 'rm -rf "$TMP"' EXIT INT TERM

TAR="${UPSTREAM_TARBALL:-$TMP/upstream.tar.gz}"
if [ -z "${UPSTREAM_TARBALL:-}" ]; then
  URL="https://codeload.github.com/$REPO/tar.gz/$REF"
  echo "==> 下载 $REPO @ $REF"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$TAR"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$TAR" "$URL"
  else
    echo "需要 curl 或 wget（或设 UPSTREAM_TARBALL 指向已下载的 tarball）" >&2
    exit 2
  fi
fi
echo "    tarball $(wc -c < "$TAR" | tr -d ' ') 字节"

mkdir -p "$TMP/up"
tar -xzf "$TAR" -C "$TMP/up" --strip-components=1

list_files() { ( cd "$1" && find . -type f | sed 's|^\./||' ); }
list_files "$TMP/up" | grep -v -E "$EXCLUDE_RE" | grep -v "^$GENERATED/" | sort > "$TMP/up.list"
list_files "$PORTAL" | grep -v "^$GENERATED/" | sort > "$TMP/loc.list"

: > "$TMP/diff.list"
: > "$TMP/only_up.list"
: > "$TMP/only_loc.list"
while IFS= read -r f; do
  if [ -f "$PORTAL/$f" ]; then
    cmp -s "$TMP/up/$f" "$PORTAL/$f" || echo "$f" >> "$TMP/diff.list"
  else
    echo "$f" >> "$TMP/only_up.list"
  fi
done < "$TMP/up.list"
while IFS= read -r f; do
  [ -f "$TMP/up/$f" ] || echo "$f" >> "$TMP/only_loc.list"
done < "$TMP/loc.list"

count() { wc -l < "$1" | tr -d ' '; }
echo "==> 上游 git 跟踪文件 $(count "$TMP/up.list") 个；本仓库 portal/（剔除生成物）$(count "$TMP/loc.list") 个"
echo "    （已按 portal/UPSTREAM.md 剔除上游的 .github .run deploy docs scripts 与 4 个根文件）"

show() {
  echo ""
  echo "=== $1（$(count "$2")）==="
  if [ -s "$2" ]; then sed 's/^/  /' "$2"; else echo "  （无）"; fi
}
show "内容不同" "$TMP/diff.list"
show "只在上游有" "$TMP/only_up.list"
show "只在本仓库有" "$TMP/only_loc.list"

STATUS=0
echo ""
if [ "$REF" = "$PINNED" ]; then
  unexpected="$(grep -v -x -F "$PATCHED" "$TMP/diff.list" || true)"
  unexpected_loc="$(grep -v -x -F "$LOCAL_EXTRA" "$TMP/only_loc.list" || true)"
  if [ -z "$unexpected" ] && [ -z "$unexpected_loc" ]; then
    echo "==> OK：与钉住的 commit $REF 相比，差异都在预期内 ——"
    if [ -s "$TMP/diff.list" ]; then
      echo "    内容不同：$PATCHED（本项目的 userspace 补丁，见 README）"
    else
      echo "    内容不同：无（$PATCHED 与上游一致：补丁可能已被上游合入，或补丁被移除，请核对）"
    fi
    echo "    只在上游有：上游的 CI / Helm chart / 文档 / 开发容器等（有意不收录，见 portal/UPSTREAM.md）"
    echo "    只在本仓库有：$LOCAL_EXTRA（本文件，上游没有）"
  else
    echo "==> 注意：出现了预期之外的差异（见上面三张清单），人工核对后再更新 portal/UPSTREAM.md" >&2
    STATUS=1
  fi
else
  echo "==> 这是与 pin（$PINNED）不同的 ref（$REF）：上面的差异反映的是上游的变动，供 rebase 参考。"
  echo "    若要把上游更新搬进来，照 portal/UPSTREAM.md「上游有变动时怎么跟进」一节做。"
fi
exit $STATUS

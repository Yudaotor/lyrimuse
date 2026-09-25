#!/usr/bin/env bash
# 从 CHANGELOG.md 抽出某个版本那一节的正文,原样打到 stdout。
#
# 用途有两个,而且**必须是同一份逻辑**:
#   1. 打 tag 的输入——docs/releasing.md「四」:
#        .github/scripts/changelog_section.sh v1.8.0 > "$TMPDIR/notes.md"
#        git tag -a v1.8.0 <验证过的 commit> -F "$TMPDIR/notes.md"
#   2. check_release_tag.sh 第 5 条守卫拿它跟 tag 注释逐字比对。
# 两处必须共用这一份,打 tag 的输入和比对的基准才不会各写各的。
#
# 输出形态 = 历史 tag 正文的形态:第一行是裸版本号(`## v1.7.0` 去掉 `## `),
# 其后是该节全文,尾部空行去掉。节边界是下一个 `^## v<数字>`,所以各节正文里别写 `## ` 开头的行;
# 也别写 `#` 开头的行 —— `git tag -F` 默认按注释删掉它们,tag 正文就会跟这一节对不上(第 5 条守卫会拦)。
#
# 用法: changelog_section.sh <tag> [CHANGELOG 路径]
# 找不到该节 → 非零退出(发版前没写日志,应当拦住)。
set -euo pipefail

usage() { echo "usage: $0 <tag> [changelog-path]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
TAG="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="${2:-$(cd "$SCRIPT_DIR/../.." && pwd)/CHANGELOG.md}"
[ -f "$CHANGELOG" ] || { echo "changelog_section: no such file: $CHANGELOG" >&2; exit 1; }

awk -v tag="$TAG" '
  # 节开头:把 "## v1.7.0" 还原成 "v1.7.0"(历史 tag 正文首行就是裸版本号)
  $0 == "## " tag { inside = 1; buf[n++] = substr($0, 4); next }
  # 下一节开始就停止收集(用 flag 不用 exit,END 里还要判空)
  inside && /^## v[0-9]/ { inside = 0 }
  inside { buf[n++] = $0 }
  END {
    if (n == 0) {
      printf "changelog_section: no \"## %s\" section in %s\n", tag, FILENAME > "/dev/stderr"
      exit 1
    }
    while (n > 0 && buf[n-1] ~ /^[ \t]*$/) n--   # 去尾部空行
    for (i = 0; i < n; i++) print buf[i]
  }
' "$CHANGELOG"

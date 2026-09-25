#!/usr/bin/env bash
# 发版 tag 构建前硬校验。release.yml 在 Checkout 之后、装任何工具链之前跑它;
# 打 tag 的人 push 前在本地跑同一份(docs/releasing.md「四」)。判据只有这一份,别在 yaml 里另写。
# 五条,任一不满足就非零退出、什么都不构建:
#   1. tag 名形态合法——委托 lyrimuse/scripts/build-version.sh(vX.Y.Z / vX.Y.Z-(alpha|beta|rc).N 的唯一定义);
#   2. 必须是 annotated tag(git cat-file -t == tag)。轻量 tag 的 %(contents) 返回的是 commit message,
#      CI 会把它当发布日志发出去;浅克隆把 annotated tag 剥成 commit 时也落在这条;
#   3. 正文去空白后非空(`git tag -a -m ''` 是能打出来的);
#   4. 正文能被 .github/scripts/split_release_notes.py 拆成中英两份——AGENTS.md「提交」的两种写法
#      (<!-- lang:en --> / <!-- lang:zh-Hans --> 标记式,或逐条中英交错式)都认,判据是两边都有实质内容,
#      不是查两行注释在不在。
#   5. 正式版 tag 的正文与 CHANGELOG.md 对应节**逐字相同**(打 tag 时由 changelog_section.sh 抽节
#      喂给 -F,这一条保证两边不分叉)。预发布 tag(vX.Y.Z-(alpha|beta|rc).N)跳过:测试版不进 CHANGELOG。
# 用法: check_release_tag.sh <tag> [--body-out FILE]
#   --body-out 把正文原样写到 FILE(CI 用它喂 appcast 与 Release 正文,正文只读这一次)。
# 报错文案用英文,跟 release.yml 其它 ::error:: 一致(CI 日志的读者不一定读中文)。
set -euo pipefail

usage() { echo "usage: $0 <tag> [--body-out FILE]" >&2; exit 2; }
[ $# -ge 1 ] || usage
TAG="$1"; shift
BODY_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body-out) [ $# -ge 2 ] || usage; BODY_OUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fail() { echo "check_release_tag: $*" >&2; exit 1; }

# 1. 形态
[[ "$TAG" == v* ]] || fail "tag '$TAG' must start with 'v' (vX.Y.Z or vX.Y.Z-(alpha|beta|rc).N)"
if ! bash "$REPO_ROOT/lyrimuse/scripts/build-version.sh" "${TAG#v}" >/dev/null; then
  fail "tag '$TAG' is not vX.Y.Z or vX.Y.Z-(alpha|beta|rc).N -- see lyrimuse/scripts/build-version.sh"
fi

# 2. annotated
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 || fail "refs/tags/$TAG does not exist in this checkout"
OBJ_TYPE="$(git cat-file -t "refs/tags/$TAG")"
if [ "$OBJ_TYPE" != "tag" ]; then
  fail "refs/tags/$TAG is a '$OBJ_TYPE' object, not an annotated tag. Either it was created without -a/-m/-F (lightweight), or this is a shallow clone that peeled the tag (CI needs fetch-depth: 0). The release notes are read from the tag annotation -- a lightweight tag would ship the commit message as the changelog."
fi

# 3. 正文。判空走 tr,不用 bash 的 "${VAR//pattern/}" 模式替换:macOS 自带 bash 3.2 对 18KB 含中文的正文做那个替换
#    要跑 98 秒(实测 v1.5.0,按多字节字符逐个扫、二次方级),tr 是毫秒级。LC_ALL=C 让 [:space:] 按字节判,避开多字节 locale 的报错。
BODY="$(git for-each-ref "refs/tags/$TAG" --format='%(contents)')"
if [ -z "$(printf '%s' "$BODY" | LC_ALL=C tr -d '[:space:]')" ]; then
  fail "tag '$TAG' has an empty annotation. Write the bilingual changelog into CHANGELOG.md, then: .github/scripts/changelog_section.sh $TAG > notes.md && git tag -a $TAG <commit> -F notes.md"
fi

# 4. 双语
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '%s\n' "$BODY" > "$TMP_DIR/notes.md"
if ! python3 "$SCRIPT_DIR/split_release_notes.py" "$TMP_DIR/notes.md" "$TMP_DIR/split" >/dev/null; then
  fail "tag '$TAG' annotation could not be split into English + Chinese release notes (see split_release_notes.py output above). Accepted formats (AGENTS.md, 提交): <!-- lang:en --> / <!-- lang:zh-Hans --> blocks, or the interleaved style (English line first, Chinese continuation indented). Each side needs real content."
fi

# 5. 与 CHANGELOG.md 对账。预发布 tag 不进 CHANGELOG,跳过。
CHANGELOG_NOTE=""
case "$TAG" in
  *-*) CHANGELOG_NOTE=", pre-release (CHANGELOG check skipped)" ;;
  *)
    CHANGELOG="$REPO_ROOT/CHANGELOG.md"
    [ -f "$CHANGELOG" ] || fail "CHANGELOG.md not found at $CHANGELOG -- release notes live there since 2026-09-16"
    if ! SECTION="$("$SCRIPT_DIR/changelog_section.sh" "$TAG" "$CHANGELOG" 2>"$TMP_DIR/section.err")"; then
      fail "tag '$TAG' has no '## $TAG' section in CHANGELOG.md ($(cat "$TMP_DIR/section.err")). Write the release notes there first, commit, then tag with: .github/scripts/changelog_section.sh $TAG > notes.md && git tag -a $TAG <commit> -F notes.md"
    fi
    printf '%s\n' "$SECTION" > "$TMP_DIR/section.md"
    printf '%s\n' "$BODY" > "$TMP_DIR/body.md"
    if ! diff -u "$TMP_DIR/section.md" "$TMP_DIR/body.md" > "$TMP_DIR/section.diff"; then
      echo "check_release_tag: tag annotation and CHANGELOG.md section differ (--- CHANGELOG / +++ tag):" >&2
      head -40 "$TMP_DIR/section.diff" >&2
      fail "tag '$TAG' annotation does not match its CHANGELOG.md section. They must be identical -- tag with: .github/scripts/changelog_section.sh $TAG > notes.md && git tag -a $TAG <commit> -F notes.md (re-tag: git tag -d $TAG first)"
    fi
    CHANGELOG_NOTE=", matches CHANGELOG.md"
    ;;
esac

if [ -n "$BODY_OUT" ]; then
  printf '%s\n' "$BODY" > "$BODY_OUT"
fi
echo "check_release_tag: $TAG ok (annotated, $(printf '%s' "$BODY" | wc -c | tr -d ' ') bytes, splits into en + zh-Hans$CHANGELOG_NOTE)"

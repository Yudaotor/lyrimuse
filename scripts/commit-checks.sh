#!/usr/bin/env bash
# 提交前的整套检查,在要提交的那棵树的根目录里跑:git-private-commit.py verify 默认就跑它,
# 也可以在任何一棵完整的树(工作区、导出的快照)根目录下手动跑。任何一步失败就停,退出码非零。
#
# 引擎那两道 CI 同款检查(go vet、死代码不得新增)只在要提交的路径里有 lyrimuse-engine/ 时跑:
# verify 把要提交的路径写进 $PRIVATE_COMMIT_CHANGED 指向的文件(每行一个);没有这份清单时两道都跑。
set -euo pipefail

if [ ! -d lyrimuse ] || [ ! -d lyrimuse-engine ]; then
  echo "!! 要在仓库那棵树的根目录里跑(这里没有 lyrimuse/ 和 lyrimuse-engine/):$(pwd)" >&2
  exit 2
fi

engine_changed=1
if [ -n "${PRIVATE_COMMIT_CHANGED:-}" ] && [ -f "$PRIVATE_COMMIT_CHANGED" ]; then
  if ! /usr/bin/grep -q '^lyrimuse-engine/' "$PRIVATE_COMMIT_CHANGED"; then
    engine_changed=0
  fi
fi

echo "==> swift build"
(cd lyrimuse && swift build)

echo "==> selftest"
(cd lyrimuse && swift run lyrimuse-selftest -q)

echo "==> Localizable.xcstrings 能解析"
/usr/bin/python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
  lyrimuse/Localization/Localizable.xcstrings

echo "==> go test"
(cd lyrimuse-engine && GOTOOLCHAIN=go1.24.4 go test ./...)

echo "==> gofmt"
unformatted="$(cd lyrimuse-engine && gofmt -l .)"
if [ -n "$unformatted" ]; then
  echo "!! 这些文件没过 gofmt:" >&2
  echo "$unformatted" >&2
  exit 1
fi

if [ "$engine_changed" = 1 ]; then
  echo "==> go vet"
  (cd lyrimuse-engine && GOTOOLCHAIN=go1.24.4 go vet ./...)

  echo "==> deadcode(不得比 deadcode-baseline.txt 多出新的)"
  dc_now="$(mktemp)"
  dc_base="$(mktemp)"
  trap 'rm -f "$dc_now" "$dc_base"' EXIT
  (cd lyrimuse-engine && GOTOOLCHAIN=go1.24.4 go run golang.org/x/tools/cmd/deadcode@v0.30.0 -test ./...) \
    | sed 's/.*unreachable func: //' | sort -u > "$dc_now"
  /usr/bin/grep -vE '^\s*(#|$)' lyrimuse-engine/deadcode-baseline.txt | sort -u > "$dc_base"
  added="$(comm -23 "$dc_now" "$dc_base")"
  if [ -n "$added" ]; then
    echo "!! 新增了死代码(删掉最后一个调用方时把函数一起删):" >&2
    echo "$added" >&2
    exit 1
  fi
else
  echo "==> go vet / deadcode:这次没改 lyrimuse-engine/,跳过"
fi

echo "==> 注释卫生"
/usr/bin/python3 scripts/check-comment-hygiene.py

echo "==> 全部通过"

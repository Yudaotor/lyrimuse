#!/usr/bin/env bash
# 提交前的整套检查,在要提交的那棵树的根目录里跑:git-private-commit.py verify 默认就跑它,
# 也可以在任何一棵完整的树(工作区、导出的快照)根目录下手动跑。任何一步失败就停,退出码非零。
#
# 引擎测试和 vet 跟 CI 同口径带 -tags devtools:带这个标签的那套包含不带标签的全部测试,vet 两种都跑。
# 引擎那两道 CI 同款检查(go vet、死代码不得新增)只在要提交的路径里有 lyrimuse-engine/ 时跑:
# verify 把要提交的路径写进 $PRIVATE_COMMIT_CHANGED 指向的文件(每行一个);没有这份清单时两道都跑。
# go test 读到的模块外文件变了时怎么重跑,见下面 go test 那段。
# verify 还给:$PRIVATE_COMMIT_TREE(这棵树的 id)、$PRIVATE_COMMIT_REPO(仓库根目录)、$PRIVATE_COMMIT_COMPILED_MARK
# (编译走完就把树的 id 写进去,校验工具据此知道这个目录接着增量编译靠得住)。手动跑时没有这些,go test 整套重跑。
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
if [ -n "${PRIVATE_COMMIT_COMPILED_MARK:-}" ] && [ -n "${PRIVATE_COMMIT_TREE:-}" ]; then
  mkdir -p "$(dirname "$PRIVATE_COMMIT_COMPILED_MARK")"
  printf '%s\n' "$PRIVATE_COMMIT_TREE" > "$PRIVATE_COMMIT_COMPILED_MARK"
fi

echo "==> selftest"
(cd lyrimuse && swift run lyrimuse-selftest -q)

echo "==> nowplaying-clients 原生测试"
sh scripts/test-nowplaying-clients.sh

if [ -f scripts/gen-feature-list.py ]; then
  echo "==> 功能清单与数据一致"
  /usr/bin/python3 scripts/gen-feature-list.py --check
fi

echo "==> Localizable.xcstrings 能解析"
/usr/bin/python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
  lyrimuse/Localization/Localizable.xcstrings

# go 的测试缓存只核对模块目录(lyrimuse-engine/)里的文件:引擎测试还读 Swift 源码、README、shared/ 这些模块外的文件,
# 它们变了缓存照样报通过。这个目录上一次 go test 通过时的树和 epoch 记在 .build/go-tested-tree;从那棵树到这一棵
# 改过的路径交给本脚本旁边的 go-test-plan.py(分析的是这棵树里的测试):none 照用缓存;一串测试名就照用缓存、再把
# 这几个带 -count=1 重跑;all 或者没有那份记录(头一次、上一次没通过、手动跑、那棵树已经找不到)就换一个 epoch
# 整套重跑。epoch 经环境变量 LYRIMUSE_GO_TEST_EPOCH 进缓存键(gotestepoch_test.go),整套重跑的结果照样进缓存。
# 这棵树里还没有 gotestepoch_test.go 时换 epoch 不起作用:不看记录、不写记录,整套带 -count=1 重跑。
echo "==> go test"
go_tested=".build/go-tested-tree"
go_epoch=""
go_count=""
go_rerun="all"
go_rerun_why="这个目录没有上一次 go test 通过的记录"
epoch_ok=0
if /usr/bin/grep -qs 'LYRIMUSE_GO_TEST_EPOCH' lyrimuse-engine/gotestepoch_test.go; then
  epoch_ok=1
else
  go_rerun_why="这棵树里还没有 gotestepoch_test.go"
fi
if [ "$epoch_ok" = 1 ] && [ -n "${PRIVATE_COMMIT_TREE:-}" ] && [ -n "${PRIVATE_COMMIT_REPO:-}" ] && [ -s "$go_tested" ]; then
  last_tree=""
  read -r last_tree go_epoch < "$go_tested" || true
  since="$(mktemp)"
  if [ -n "$go_epoch" ] \
      && git -C "$PRIVATE_COMMIT_REPO" diff --name-only "$last_tree" "$PRIVATE_COMMIT_TREE" > "$since" 2>/dev/null \
      && plan="$(/usr/bin/python3 "$(dirname "${BASH_SOURCE[0]}")/go-test-plan.py" --engine lyrimuse-engine "$since")"; then
    go_rerun="$plan"
    go_rerun_why="读到的模块外文件在上一次通过之后改过"
  fi
  rm -f "$since"
fi
rm -f "$go_tested"
if [ "$go_rerun" = all ]; then
  go_epoch="${PRIVATE_COMMIT_TREE:-$(date +%s)}"
  if [ "$epoch_ok" = 0 ]; then go_count="-count=1"; fi
  echo "    整套重跑($go_rerun_why)"
fi
(cd lyrimuse-engine && LYRIMUSE_GO_TEST_EPOCH="$go_epoch" GOTOOLCHAIN=go1.24.4 go test -tags devtools ${go_count:+"$go_count"} ./...)
case "$go_rerun" in
  all | none) ;;
  *)
    echo "    带 -count=1 重跑($go_rerun_why):$go_rerun"
    (cd lyrimuse-engine && LYRIMUSE_GO_TEST_EPOCH="$go_epoch" GOTOOLCHAIN=go1.24.4 \
      go test -tags devtools -count=1 -run "$go_rerun" .)
    ;;
esac
if [ "$epoch_ok" = 1 ] && [ -n "${PRIVATE_COMMIT_TREE:-}" ]; then
  mkdir -p .build
  printf '%s %s\n' "$PRIVATE_COMMIT_TREE" "$go_epoch" > "$go_tested"
fi

echo "==> gofmt"
unformatted="$(cd lyrimuse-engine && gofmt -l .)"
if [ -n "$unformatted" ]; then
  echo "!! 这些文件没过 gofmt:" >&2
  echo "$unformatted" >&2
  exit 1
fi

if [ "$engine_changed" = 1 ]; then
  echo "==> go vet(不带标签 / -tags devtools)"
  (cd lyrimuse-engine && GOTOOLCHAIN=go1.24.4 go vet ./... && GOTOOLCHAIN=go1.24.4 go vet -tags devtools ./...)

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

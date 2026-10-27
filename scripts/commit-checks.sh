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
# PRIVATE_COMMIT_LIGHT=1(轻校验:commit --retry 在 rebase 进来的提交跟这次的路径没有交集时给):只重新编译、做静态检查,
# 不跑 selftest、原生测试和 go test,也不更新 go test 通过的记录,下一次完整校验照样把这段改动算进去。见 15 章决策 80。
set -euo pipefail

if [ ! -d lyrimuse ] || [ ! -d lyrimuse-engine ]; then
  echo "!! 要在仓库那棵树的根目录里跑(这里没有 lyrimuse/ 和 lyrimuse-engine/):$(pwd)" >&2
  exit 2
fi

# 全机重活闸(heavy-gate.sh):整套检查跟 build.sh 的编译共用,同一台机器同时最多两份,有装机在等时让它先。
. "$(dirname "$0")/heavy-gate.sh"
static_pid=""
# 退出时先等后台那份 vet / deadcode 跑完再放闸:不等的话它会在下一个会话已经同步进来的目录里接着跑。
on_exit() {
  if [ -n "$static_pid" ]; then wait "$static_pid" 2>/dev/null || true; fi
  heavy_gate_release
}
trap on_exit EXIT
heavy_gate_acquire "提交校验 $(basename "$(pwd)")" check

# 每一步打出用了几秒(下一步开始、或全部通过时打上一步的),排查「校验为什么慢」看这几行。
checks_t0="$(date +%s)"
step_name=""
step_t0="$checks_t0"
step() {
  local now
  now="$(date +%s)"
  if [ -n "$step_name" ]; then echo "    ($step_name:$((now - step_t0)) 秒)"; fi
  step_name="$1"
  step_t0="$now"
  echo "==> $1"
}

engine_changed=1
if [ -n "${PRIVATE_COMMIT_CHANGED:-}" ] && [ -f "$PRIVATE_COMMIT_CHANGED" ]; then
  if ! /usr/bin/grep -q '^lyrimuse-engine/' "$PRIVATE_COMMIT_CHANGED"; then
    engine_changed=0
  fi
fi

# 只读源码和数据文件、不依赖编译产物的几步排在 swift build 前面,几秒内就报错(见 15 章决策 85)。
if [ -f scripts/gen-feature-list.py ]; then
  step "功能清单与数据一致"
  /usr/bin/python3 scripts/gen-feature-list.py --check
fi

step "Localizable.xcstrings 能解析"
/usr/bin/python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
  lyrimuse/Localization/Localizable.xcstrings

step "generate-strings.py 自检"
/usr/bin/python3 -B lyrimuse/Localization/generate-strings.py --selftest

step "swift build"
(cd lyrimuse && swift build)
if [ -n "${PRIVATE_COMMIT_COMPILED_MARK:-}" ] && [ -n "${PRIVATE_COMMIT_TREE:-}" ]; then
  mkdir -p "$(dirname "$PRIVATE_COMMIT_COMPILED_MARK")"
  printf '%s\n' "$PRIVATE_COMMIT_TREE" > "$PRIVATE_COMMIT_COMPILED_MARK"
fi

light="${PRIVATE_COMMIT_LIGHT:-}"
if [ -n "$light" ]; then
  step "selftest、nowplaying-clients 原生测试:轻校验,跳过"
else
  step "selftest"
  (cd lyrimuse && swift run lyrimuse-selftest -q)

  step "nowplaying-clients 原生测试"
  sh scripts/test-nowplaying-clients.sh
fi

step "发布版写过的偏好键删掉后登记成死键"
/usr/bin/python3 -B scripts/check-retired-defaults.py --repo "${PRIVATE_COMMIT_REPO:-.}"

# 引擎测试由同目录的 go-test-shards.py 分几个进程并行跑(见它的头注),不走 go 自己的测试缓存:那份缓存只核对模块
# 目录(lyrimuse-engine/)里的文件,引擎测试还读 Swift 源码、README、shared/ 这些模块外的文件。要不要跑、跑哪几个在
# 这里按改动定:这个目录上一次 go test 通过时的树记在 .build/go-tested-tree,从那棵树到这一棵 lyrimuse-engine/ 下
# 有改动就整套跑;只改了模块外的文件,交给 go-test-plan.py(分析的是这棵树里的测试):none 跳过,一串测试名就只跑
# 这几个,all 整套跑。没有那份记录(头一次、上一次没通过、手动跑、那棵树已经找不到)也整套跑。
# go vet 和 deadcode(不得比 deadcode-baseline.txt 多出新的)跟 go test 互不依赖:改了引擎时在 go test 之前放到后台跑,
# 后面到它那一步再等结果。
engine_static_checks() {
  # -trimpath 跟 go-test-shards.py 一样:各校验目录共用 go 的编译缓存。
  (cd lyrimuse-engine && GOTOOLCHAIN=go1.24.4 go vet -trimpath ./... \
    && GOTOOLCHAIN=go1.24.4 go vet -trimpath -tags devtools ./...) || return 1
  local dc_now dc_base added rc=0
  dc_now="$(mktemp)"
  dc_base="$(mktemp)"
  if ! (cd lyrimuse-engine && GOTOOLCHAIN=go1.24.4 go run golang.org/x/tools/cmd/deadcode@v0.30.0 -test ./...) \
      | sed 's/.*unreachable func: //' | sort -u > "$dc_now"; then
    echo "!! deadcode 没跑成" >&2
    rc=1
  else
    /usr/bin/grep -vE '^\s*(#|$)' lyrimuse-engine/deadcode-baseline.txt | sort -u > "$dc_base"
    added="$(comm -23 "$dc_now" "$dc_base")"
    if [ -n "$added" ]; then
      echo "!! 新增了死代码(删掉最后一个调用方时把函数一起删):" >&2
      echo "$added" >&2
      rc=1
    fi
  fi
  rm -f "$dc_now" "$dc_base"
  return $rc
}
static_log=".build/engine-static.log"
if [ "$engine_changed" = 1 ]; then
  mkdir -p .build
  engine_static_checks > "$static_log" 2>&1 &
  static_pid=$!
fi

if [ -n "$light" ]; then
  if [ "$engine_changed" = 1 ]; then
    step "go test:轻校验,跳过(引擎的编译和类型检查由后台的 go vet 做)"
  else
    step "go vet:轻校验,只编译、类型检查引擎和它的测试"
    (cd lyrimuse-engine && GOTOOLCHAIN=go1.24.4 go vet -trimpath -tags devtools ./...)
  fi
else
  step "go test"
  go_tested=".build/go-tested-tree"
  go_rerun="all"
  go_rerun_why="这个目录没有上一次 go test 通过的记录"
  if [ -n "${PRIVATE_COMMIT_TREE:-}" ] && [ -n "${PRIVATE_COMMIT_REPO:-}" ] && [ -s "$go_tested" ]; then
    last_tree=""
    read -r last_tree _ < "$go_tested" || true
    since="$(mktemp)"
    if [ -n "$last_tree" ] \
        && git -C "$PRIVATE_COMMIT_REPO" diff --name-only "$last_tree" "$PRIVATE_COMMIT_TREE" > "$since" 2>/dev/null; then
      if /usr/bin/grep -q '^lyrimuse-engine/' "$since"; then
        go_rerun_why="引擎代码在上一次通过之后改过"
      elif plan="$(/usr/bin/python3 "$(dirname "${BASH_SOURCE[0]}")/go-test-plan.py" --engine lyrimuse-engine "$since")"; then
        go_rerun="$plan"
        go_rerun_why="读到的模块外文件在上一次通过之后改过"
      fi
    fi
    rm -f "$since"
  fi
  rm -f "$go_tested"
  go_shards="$(dirname "${BASH_SOURCE[0]}")/go-test-shards.py"
  case "$go_rerun" in
    none)
      echo "    跳过(这个目录上一次通过之后,引擎和它读的模块外文件都没改)"
      ;;
    all)
      echo "    整套跑($go_rerun_why)"
      /usr/bin/python3 -B "$go_shards" lyrimuse-engine
      ;;
    *)
      echo "    只跑这几个($go_rerun_why):$go_rerun"
      /usr/bin/python3 -B "$go_shards" lyrimuse-engine --run "$go_rerun"
      ;;
  esac
  if [ -n "${PRIVATE_COMMIT_TREE:-}" ]; then
    mkdir -p .build
    printf '%s\n' "$PRIVATE_COMMIT_TREE" > "$go_tested"
  fi
fi

step "gofmt"
unformatted="$(cd lyrimuse-engine && gofmt -l .)"
if [ -n "$unformatted" ]; then
  echo "!! 这些文件没过 gofmt:" >&2
  echo "$unformatted" >&2
  exit 1
fi

if [ "$engine_changed" = 1 ]; then
  step "go vet / deadcode(跟 go test 一起在后台跑,这里只等结果)"
  static_rc=0
  wait "$static_pid" || static_rc=$?
  static_pid=""
  cat "$static_log"
  if [ "$static_rc" != 0 ]; then exit 1; fi
else
  step "go vet / deadcode:这次没改 lyrimuse-engine/,跳过"
fi

# 只扫这次提交改到的文件(没改的提交时都扫过);改的是检查脚本自己、或者没有改动清单(手动跑)时扫全仓,
# 不带参数时脚本还会先自检。
step "注释卫生"
hygiene_files=()
if [ -n "${PRIVATE_COMMIT_CHANGED:-}" ] && [ -f "$PRIVATE_COMMIT_CHANGED" ] \
    && ! /usr/bin/grep -qx 'scripts/check-comment-hygiene.py' "$PRIVATE_COMMIT_CHANGED"; then
  while IFS= read -r f; do
    if [ -f "$f" ]; then hygiene_files+=("$f"); fi
  done < "$PRIVATE_COMMIT_CHANGED"
  if [ "${#hygiene_files[@]}" -gt 0 ]; then
    echo "    只扫这次改到的 ${#hygiene_files[@]} 个文件"
    /usr/bin/python3 -B scripts/check-comment-hygiene.py "${hygiene_files[@]}"
  else
    echo "    这次没有要扫的文件"
  fi
else
  /usr/bin/python3 -B scripts/check-comment-hygiene.py
fi

step "全部通过"
echo "    (合计 $(( $(date +%s) - checks_t0 )) 秒)"

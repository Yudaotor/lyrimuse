#!/usr/bin/env bash
# 只重建引擎到仓库根的 bin/lyrimuse-engine,给手动 -dry-run、单独跑子命令调试用。重建时用本脚本,别直接 `go build`。
#
# 为什么：系统 Go 是 1.21（工作项目锁定，别动），它的内部链接器在这台 macOS 27 上
# 产出的二进制缺 LC_UUID / 签名不被 AMFI 接受 → launchd 会静默拒启（报误导性的
# "dyld: missing LC_UUID" / 退出原因 OS_REASON_CODESIGNING），采集器起不来、网页停更。
# 解法：用 GOTOOLCHAIN 临时拉 go1.24 工具链重编，它原生就发 LC_UUID + 合规签名，
# 不用任何 -ldflags 花招、也不用手动 codesign。系统 Go 仍留 1.21、不受影响。
#
# 不碰 /Applications/Lyrimuse.app,也不重启 launchd 管的那份引擎。往已装好的包里换引擎只走
# lyrimuse/build.sh:它拿排队锁、先删再拷(同一个 inode 上反复覆盖会被内核按签名无效 SIGKILL,见那份脚本
# 装配引擎那段注释)、重新签整个包。在这里直接 cp 进去会让外层签名对不上包内容,而且绕开排队锁。
#
# 用法：
#   ./build.sh   构建 bin/lyrimuse-engine(`--no-restart` 照旧接受,本来就不重启)
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse-engine/
BIN="../bin/lyrimuse-engine"
TOOLCHAIN=go1.24.4 # 原生发 LC_UUID + 有效签名的工具链

case "${1:-}" in
  "" | --no-restart) ;;
  *)
    echo "!! 不认识的参数:$1(用法见脚本开头)" >&2
    exit 2
    ;;
esac

# 注入版本号,两个构建脚本都用 -ldflags 注入,见 15 章决策 9。
#   ① LYRIMUSE_VERSION 环境变量(显式指定,最高优先)
#   ② 最近一个 git tag
#   ③ dev(一眼假值,见 main.go clientVersion 注释里"为什么不写具体版本号")
ENGINE_VERSION="${LYRIMUSE_VERSION:-}"
[ -z "$ENGINE_VERSION" ] && ENGINE_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -z "$ENGINE_VERSION" ] && ENGINE_VERSION="dev"

echo "==> building with $TOOLCHAIN (native LC_UUID + valid signature), version $ENGINE_VERSION"
# -X 只能注入 var,对 const 静默失败——见 main.go clientVersion 那段注释。-s -w 跟 lyrimuse/build.sh 一致,
# 见 15 章决策 33。
GOTOOLCHAIN="$TOOLCHAIN" go build -ldflags "-s -w -X main.clientVersion=$ENGINE_VERSION" -o "$BIN" .
codesign -v "$BIN" && echo "    signature valid"

# launchd 管的那份是打包进 Lyrimuse.app 里的引擎(见 LyrimusePaths.bundledEnginePath),不是这份。
echo "==> built $BIN"
echo "    要让正在跑的那份用上:cd ../lyrimuse && ./build.sh(重打包、重签名、重启 App 和引擎)"

#!/usr/bin/env bash
# 重建并重启 now-playing 采集器。重建时务必用本脚本，别直接 `go build`。
#
# 为什么：系统 Go 是 1.21（工作项目锁定，别动），它的内部链接器在这台 macOS 27 上
# 产出的二进制缺 LC_UUID / 签名不被 AMFI 接受 → launchd 会静默拒启（报误导性的
# "dyld: missing LC_UUID" / 退出原因 OS_REASON_CODESIGNING），采集器起不来、网页停更。
# 解法：用 GOTOOLCHAIN 临时拉 go1.24 工具链重编，它原生就发 LC_UUID + 合规签名，
# 不用任何 -ldflags 花招、也不用手动 codesign。系统 Go 仍留 1.21、不受影响。
#
# 用法：
#   ./build.sh              构建 + 通过 launchd 重启
#   ./build.sh --no-restart 只构建，不动正在运行的进程
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse-collector/
BIN="../bin/collector"
BUNDLED_BIN="/Applications/Lyrimuse.app/Contents/Resources/collector"
LABEL="com.lyrimuse.collector"
TOOLCHAIN=go1.24.4 # 原生发 LC_UUID + 有效签名的工具链

# 注入版本号,让这份 collector 自报的版本跟它将要替换掉的那份保持一致。
#
# 2026-09-02 加(同 lyrimuse/build.sh 那处,理由见 main.go 的 clientVersion 注释):
# collector 版本号以前是 main.go 里的手写字面量,发版时靠人记得改,v1.3.0 和 v1.5.0
# 各漏过一次。现在两个构建脚本统一用 -ldflags 注入。
#
# 取值优先级刻意跟 lyrimuse/build.sh **不完全相同**,因为这个脚本的用途不一样:它把
# 产物直接拷进**已经装好的** /Applications/Lyrimuse.app(见下面那段注释),所以第一
# 顺位应该是"那个 App 自己是什么版本",而不是 git tag——本地 tag 完全可能落后于已装
# 的 App(比如装的是 CI 发的 1.5.0,而本地仓库最新 tag 还是 v1.4.0),那时用 git tag
# 反而会亲手制造出这次要修的那种不一致。
#   ① LYRIMUSE_VERSION 环境变量(显式指定,最高优先)
#   ② 已安装 App 的 CFBundleShortVersionString(产物要拷进去,必须跟它对齐)
#   ③ 最近一个 git tag(App 还没装时的兜底)
#   ④ dev(一眼假值,见 main.go clientVersion 注释里"为什么不写具体版本号")
COLLECTOR_VERSION="${LYRIMUSE_VERSION:-}"
if [ -z "$COLLECTOR_VERSION" ] && [ -f "$BUNDLED_BIN" ]; then
  COLLECTOR_VERSION="$(plutil -extract CFBundleShortVersionString raw \
    /Applications/Lyrimuse.app/Contents/Info.plist 2>/dev/null || true)"
fi
[ -z "$COLLECTOR_VERSION" ] && COLLECTOR_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -z "$COLLECTOR_VERSION" ] && COLLECTOR_VERSION="dev"

echo "==> building with $TOOLCHAIN (native LC_UUID + valid signature), version $COLLECTOR_VERSION"
# ⚠️ -X 只能注入 var,对 const 静默失败——见 main.go clientVersion 那段注释。
GOTOOLCHAIN="$TOOLCHAIN" go build -ldflags "-X main.clientVersion=$COLLECTOR_VERSION" -o "$BIN" .
codesign -v "$BIN" && echo "    signature valid"

# 2026-07-21 起 collector 真正被 launchd 管的那份是打包进 Lyrimuse.app 里的
# Contents/Resources/collector(见 CollectorServiceManager.swift)，不再是仓库自己的
# bin/collector——这里额外拷贝一份进已安装的 .app 包，这样改 collector 代码不用重新
# swift build 整个 App 就能验证到"真正在跑的那份"。bin/collector 这份继续保留，纯粹
# 方便手动 -dry-run 调试，不再是生产上跑的那份。
RUNTIME_BIN="$BIN"
if [ -d /Applications/Lyrimuse.app ]; then
  cp "$BIN" "$BUNDLED_BIN"
  codesign -v "$BUNDLED_BIN" && echo "    bundled copy signature valid"
  RUNTIME_BIN="$BUNDLED_BIN"
fi

if [ "${1:-}" = "--no-restart" ]; then
  echo "==> built (restart skipped)"
  exit 0
fi

echo "==> restarting via launchd"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
sleep 3
if ! pgrep -f "$RUNTIME_BIN" >/dev/null 2>&1; then
  # kickstart 有时会静默失败——launchd 给这个 job 缓存了上一次运行遗留的 LWCR
  # (Lightweight Code Requirement)codesigning 约束,绑定的是旧二进制的 cdhash;
  # 每次重建都是新的 codesign,cdhash 必然变化,kickstart 本身不会刷新这个约束,
  # 新二进制会被 OS 直接拒绝启动。只有完整卸载再重新加载这个 job,才会让 launchd
  # 丢掉旧约束、重新从 plist/二进制读起(lyrimuse/build.sh 实测坐实过这个
  # 失败模式和这个修法)。
  echo "==> kickstart produced no running process, retrying via bootout+bootstrap"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  # bootout 是异步的,launchd 需要一点时间才会真正把这个 job 卸载干净——紧接着就
  # bootstrap 同一个 label 有时会因为卸载还没完成而失败/静默无效(lyrimuse/
  # build.sh 实测坐实过:不加这个间隔,这条自愈分支本身也会偶尔失败,需要手动再重试
  # 一遍才行)。
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  sleep 1
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  sleep 2
fi
if pid=$(pgrep -f "$RUNTIME_BIN"); then
  echo "==> collector running, pid $pid"
else
  echo "!! collector not running — see ~/Library/Logs/lyrimuse.log" >&2
  exit 1
fi

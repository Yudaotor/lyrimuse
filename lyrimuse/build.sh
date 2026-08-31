#!/usr/bin/env bash
# 重建桌面歌词悬浮窗 App，打包成正经的 .app 装进 bin/ 里(2026-07-18 起——之前是裸
# 可执行文件靠 NSApp.setActivationPolicy(.accessory) 表现成菜单栏应用，用户反馈想要
# 能从 Dock/Finder 双击启动，改成打包成真正的 .app bundle；LSUIElement 仍然让它运行期间
# 不占 Dock/Cmd-Tab，只是现在多了一个可以拖进 Dock 当启动器用的图标)。这是用户随时可能
# 主动 Cmd-Q 退出的前台 GUI 工具，不是 KeepAlive 常驻服务——"重启"这一步只是"如果当前有
# 实例在跑就杀掉旧的、拉起新构建的"，不碰开机启动的 LaunchAgent 配置(那是用户在 App 菜单
# 里自己控制的开关，见 Settings/LoginItemManager.swift)。
#
# 用法:
#   ./build.sh                构建本机架构 + 装到 /Applications + 重启(如果当前有实例在跑)
#   ./build.sh --universal    构建 arm64 + x86_64 的 universal 包(给 Intel 用户的兼容包)
#   ./build.sh --no-restart   只构建,不重启
#   ./build.sh --dest <路径>  组装到指定路径而不是 /Applications(隐含 --no-restart),
#                             供 package.sh 一次跑出两种架构的包
#
# 2026-08-06 这里改过两轮,最终定成"分开发两份",过程值得记下来免得又绕回去:
#
# 起因是发现 v1.0.0~v1.2.0 发出去的全是 arm64-only —— 发布包在本机手动打,而这里当时默认
# 只编本机架构,cask 只写 `depends_on macos: :sonoma`、appcast 只写 minimumSystemVersion,
# 两个都不管架构,Intel Mac 上装得上、打开直接失败。于是先把默认改成了 universal。
#
# 但随后在这台 macOS 27 上实测到:包里一旦含 x86_64 代码,系统会弹"需要更新 App —— 此版本
# 包含的一个组件无法在下个主要版本 macOS 28 中打开"(macOS 28 移除 Rosetta)。这条告警会打在
# **多数用户**(Apple Silicon)脸上,而 App 本身一点问题都没有 —— 对一个开源项目来说,看着
# 像已废弃比少支持一批老机器更伤。
#
# 所以最终形态(打包见 package.sh):
#   - 主包 arm64-only:彻底不含 x86_64,不会触发那条告警,下载体积也小一半
#   - Intel 兼容包 universal:单独一份资产,只引导 Intel 用户下
#   - appcast 里主包那条 item 带子元素 <sparkle:hardwareRequirements>arm64</...> —— Sparkle 在 Intel 客户端
#     上会判定该条不适用而跳过(见 SPUAppcastItemStateResolver.isArm64HardwareRequirementOK,
#     它自己的注释就写着 "macOS 27+ will no longer support Intel Macs"),只会说"已是最新",
#     不会给 Intel 用户推一个跑不起来的包
# 默认因此回到"本机架构";两种包由 package.sh 显式各要一次,不依赖谁记得传参数。
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse/

NO_RESTART=0
UNIVERSAL=0
DEST=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-restart) NO_RESTART=1 ;;
    --universal) UNIVERSAL=1 ;;
    --dest)
      shift
      DEST="${1:-}"
      [ -n "$DEST" ] || { echo "!! --dest 需要一个路径" >&2; exit 2; }
      ;;
    *) echo "!! 未知参数:$1(可用:--universal / --no-restart / --dest <路径>)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$UNIVERSAL" = 1 ]; then
  ARCHES="arm64 x86_64"
else
  ARCHES="$(uname -m)"
fi
# --dest 是给打包用的:组装到别处就不该去碰用户正在跑的那个实例。
[ -n "$DEST" ] && NO_RESTART=1
# 单架构时直接拷,不套一层只含一个架构的 fat 文件(那种文件能跑,但没必要)。
merge_slices() {
  local out="$1"; shift
  if [ "$#" -eq 1 ]; then cp "$1" "$out"; else lipo -create "$@" -output "$out"; fi
}

APP_NAME="Lyrimuse"
# X.Y.Z 语义化版本——检查更新功能(UpdateChecker.swift)靠 CFBundleShortVersionString
# 跟 GitHub Release 的 tag(去掉 v 前缀)比大小,必须是干净的三段数字。CI(release.yml)
# 在真正打 tag 触发时会传入 LYRIMUSE_VERSION 环境变量(从 tag 解析出的真实版本号);
# 本地手动跑不设这个变量。
#
# ⚠️ 2026-08-27 之前这里的默认值硬编码成 "1.0.0"——本地构建本来就不是要发布的正式
# 版本,当时觉得不需要精确。实测坐实这个假设是错的:这台机器上唯一会用到的构建方式
# 就是本地 `./build.sh`(见 repo CLAUDE.md),诊断导出的「App version」这一行因此
# 永远报 1.0.0,即便实际代码已经是 v1.4.0 之后好几轮迭代——同一份诊断报告里 collector
# 侧日志正确打出 `lyrimuse 1.4.0 starting`,App 侧却报 1.0.0,两个版本号当场打架,
# 排查时反而添乱。改成取最近一个 git tag(去掉 v 前缀)当默认值——不追新 commit 也
# 不带 hash 后缀,保持"干净三段数字"这条硬约束,但至少不会常年停在一个早就过时的
# 占位值上;真拿不到 tag(比如浅克隆、不是 git 仓库)才退到 0.0.0 这个一眼假的占位值,
# 不会看着像一个正常但过时的版本号。
APP_VERSION="${LYRIMUSE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
[ -z "$APP_VERSION" ] && APP_VERSION="0.0.0"
# 装到 /Applications/ 而不是仓库自己的 bin/ 里(2026-07-18 当天改的——一开始装在 bin/
# 下,用户把它拖/拷到了 /Applications/ 自己启动,导致真正在跑的是一份没同步过后续几次
# 修复的旧拷贝,重新构建/重启了好几次都没反映到用户实际在看的那个进程上,排查了很久才
# 发现。/Applications/ 才是这个 App 实际使用的位置,以后 build.sh 直接装到这里，不再
# 留一份 bin/ 下的拷贝，避免"到底哪份是真的在跑"这种混乱再发生一次)。
# 默认装到 /Applications;--dest 让 package.sh 把包组装到暂存目录,好一次产出多种架构。
# ⚠️ 2026-08-31:不再**就地**组装 /Applications 里那个包。
#
# 起因是多会话协作时反复撞车:两个会话同时跑 build.sh,一个正往 /Applications/Lyrimuse.app
# 里增删改签、另一个同时在改同一个包,实测撞出过两种表现——
#   * `install_name_tool: cannot rename .../Contents/MacOS/lyrimuse (No such file or directory)`
#     (文件在 rename 之前被对方删掉了)
#   * `Bootstrap failed: 5: Input/output error`(launchd 拿到一个写到一半的 bundle,
#     App 起来了、collector 没起来)
# 根因不是"安装那一步"没做互斥,而是从这一行往下近 340 行**全部**在原地增删改签同一个包
# (mkdir/cp/rm -rf/lipo+mv/codesign --force),整段都是不安全窗口。
#
# 改法:装配全程在一个**同目录兄弟路径**的暂存包里做,最后一次性换进去(见下面 swap 那段)。
# 暂存目录刻意不用 `mktemp -d`:TMPDIR 可以被指到别的卷,而跨卷 rename 会 EXDEV;
# 放在 $APP_DIR 的同级目录,同卷由构造保证。
#
# ⚠️ --dest(package.sh 用)**不套暂存**:它本来就装到自己的 mktemp 暂存目录、随后自己打包,
# 不存在"替换一个正在被使用的安装"这回事,再套一层只会绕。package.sh 的行为逐字不变。
FINAL_APP_DIR="${DEST:-/Applications/${APP_NAME}.app}"
if [ -n "$DEST" ]; then
  APP_DIR="$FINAL_APP_DIR"
  STAGE=""
else
  # 上一次被 SIGKILL 打断时 trap 不会执行,会留下暂存包。开头按**精确前缀**逐个清掉,
  # 不用通配 rm(前缀写死、只删自己这个脚本造的东西)。
  for stale in "$(dirname "$FINAL_APP_DIR")/.${APP_NAME}.app.stage."*; do
    [ -e "$stale" ] && rm -rf "$stale"
  done
  STAGE="$(dirname "$FINAL_APP_DIR")/.${APP_NAME}.app.stage.$$"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  # 这个脚本原来一个 trap 都没有(package.sh 有)。装配中途失败/被 Ctrl-C 时必须把暂存包
  # 收走,否则 /Applications 下会慢慢攒垃圾。⚠️ swap 之后 $STAGE 指向的是**旧包**,
  # 这个 trap 同时也就是"装完把旧包删掉"那一步,不用另写。
  trap 'rm -rf "$STAGE"' EXIT
  APP_DIR="$STAGE"
fi
BIN="$APP_DIR/Contents/MacOS/lyrimuse"
# 2026-07-20:App 正式改名 Lyrimuse 这次,把 LABEL(codesign --identifier / launchd
# Label,TCC 自动化权限按这个认)和 Info.plist 的 CFBundleIdentifier(UserDefaults
# 偏好域按这个认)一起统一改成同一个反向域名式字符串——早先(2026-07-18 打包成 .app
# 那次)特意把这两者分开,是因为那次只是"裸可执行文件→.app 包"的格式迁移,需要
# CFBundleIdentifier 继续等于旧的裸可执行文件隐式落的偏好域名"desktop-lyrics"、才能
# 无缝接上已有设置;这次是主动做一次完整改名+一次性数据迁移(见下方 UserDefaults
# 迁移步骤),不再需要保留那个历史包袱,直接统一成标准写法更清爽。副作用:改这两个
# 字符串意味着 TCC 会认成一个新 App,自动化权限(控制 Music.app 播放)会重新弹一次
# 系统授权对话框——这是这次改名一次性的代价,同意一次之后往后都不会再弹。
LABEL="me.yudaotor.lyrimuse"
# 合并后的二进制放这里。**不要**用 .build/release —— 那是个指向"最后一次构建的那个
# 架构"的符号链接,多架构循环里它会在中途被改指向,拿它取产物必然错(2026-08-06 实测:
# 跑完一次 `swift build --arch x86_64` 之后 .build/release 就指向
# x86_64-apple-macosx/release 了)。
# ⚠️ 2026-08-31 从固定的 ".build/fat" 改成 per-run 临时目录。原来是所有会话共用同一个
# 路径,而下面这句 `rm -rf` 会把**另一个会话刚 lipo 出来的切片**一起删掉,那边随后 cp 到
# 空气(或者拷到一个只写了一半的文件)。SwiftPM 的 .build/.lock 只锁 `swift build` 本身,
# 管不到这里。跟上面的暂存包是同一族问题(共享可写路径),顺手一并修掉。
FAT_DIR="$(mktemp -d)"

echo "==> building (release) [$ARCHES]"
# 每个架构单独编一次再 lipo 合并,而不是 `swift build --arch arm64 --arch x86_64` 一步
# 出 universal —— 后者要走 xcbuild
# (/Library/Developer/SharedFrameworks/XCBuild.framework/.../xcbuild),那是**完整 Xcode**
# 才有的组件,只装 Command Line Tools 的机器上直接报 "xcbuild executable ... does not
# exist or is not executable"(2026-08-06 实测)。单 --arch 交叉编译不经过 xcbuild,可用。
SWIFT_SLICES=()
TRANSLATE_SLICES=()
for arch in $ARCHES; do
  swift build -c release --arch "$arch"
  # 产物目录问 --show-bin-path,不硬编码 ".build/<arch>-apple-macosx/release"。
  BIN_PATH="$(swift build -c release --arch "$arch" --show-bin-path)"
  SWIFT_SLICES+=("$BIN_PATH/lyrimuse")
  TRANSLATE_SLICES+=("$BIN_PATH/lyrics-translate")
done
merge_slices "$FAT_DIR/lyrimuse" "${SWIFT_SLICES[@]}"
merge_slices "$FAT_DIR/lyrics-translate" "${TRANSLATE_SLICES[@]}"

# 2026-07-21:collector 现在打包进 .app 里(见 Contents/Resources/collector),不再要求
# 用户手动单独构建它——CollectorServiceManager.swift 靠 Bundle.main.bundleURL 精确知道
# 它在哪，跟 LoginItemManager 认自己的方式一样。跟 lyrimuse-collector/build.sh 同款
# GOTOOLCHAIN=go1.24.4(系统 Go 1.21 产出的二进制缺 LC_UUID，AMFI 拒签，见那份脚本的
# 注释)。
echo "==> building collector [$ARCHES]"
# collector 是纯 Go(没有 import "C",2026-08-06 核实过),所以 GOARCH 交叉编译不需要交叉
# 工具链,直接编两份再 lipo 合并即可。GOARCH 的写法跟 uname -m 不一样:x86_64 在 Go 里
# 叫 amd64。
COLLECTOR_SLICES=()
for arch in $ARCHES; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "!! 不认识的架构:$arch" >&2; exit 2 ;;
  esac
  # ⚠️ 这里**不能**再加 "$PWD/" 前缀。下一行进了子 shell(`cd ../lyrimuse-collector`),
  # 所以 -o 的落点必须是绝对路径 —— 当 FAT_DIR 还是相对的 ".build/fat" 时,靠 "$PWD/"
  # 补齐正是必需的。2026-08-31 把 FAT_DIR 改成 `mktemp -d`(绝对路径,理由见它声明处)
  # 之后,这个前缀就变成了拼接错误:"$PWD" + "/var/folders/…" 造出
  # `lyrimuse/var/folders/…/collector-arm64`,每次构建往仓库里丢一份产物 —— 提交前
  # 发现时已经攒了 330MB、183 个未跟踪条目里就有它。FAT_DIR 现在自己就是绝对路径,直接用。
  out="$FAT_DIR/collector-$arch"
  (cd ../lyrimuse-collector && GOTOOLCHAIN=go1.24.4 GOOS=darwin GOARCH="$goarch" go build -o "$out" .)
  COLLECTOR_SLICES+=("$out")
done
merge_slices "$FAT_DIR/collector" "${COLLECTOR_SLICES[@]}"

echo "==> assembling .app bundle"
# CFBundleIdentifier 这次(2026-07-20 改名 Lyrimuse)跟上面的 $LABEL 统一成同一个
# 字符串——早先(2026-07-18 打包成 .app 那次)故意让两者不同,是因为 CFBundleIdentifier
# 需要继续等于裸可执行文件时代 UserDefaults.standard 隐式落的偏好域名"desktop-lyrics"、
# 才能让新打包的 .app 无缝接上旧设置。这次是主动做一次完整改名,旧的 UserDefaults 数据
# 已经用一次性脚本从"desktop-lyrics"域迁移到新域,不再需要靠"保持 CFBundleIdentifier
# 不变"这个手段来保护旧设置,直接统一成标准的反向域名写法。
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$FAT_DIR/lyrimuse" "$BIN"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# collector 装在 Resources/ 而不是 MacOS/——那里是 CFBundleExecutable 指向的主执行文件，
# collector 是被 launchd 单独拉起的后台辅助二进制，不是这个 App 自己的入口。
#
# 2026-07-24 实测坐实一个严重问题：反复在同一路径上 `cp`(不删旧文件、复用同一个
# inode)覆盖这个可执行文件很多次之后，内核的代码签名信任判定会失效——表现是这个
# 二进制不管谁来起(不只是 launchd 管的常驻服务，"歌词管理"窗口"搜索候选歌词"那种
# 一次性子进程调用同样中招)全部被 SIGKILL，诊断报告(~/Library/Logs/
# DiagnosticReports/collector-*.ips)里能看到明确原因："SIGKILL (Code Signature
# Invalid)" / namespace CODESIGNING / indicator "Taskgated Invalid Signature"——
# 即使当时用 `codesign -v` 单独验证这个文件本身完全通过。跟主执行文件($BIN)的处境
# 不同:那个在下面会被 `codesign --force` 显式重新签名一次，这里 collector 从
# `go build` 产物原样拷过来，从没有在 build.sh 里被重新签过，长期反复覆盖同一个
# inode 更容易踩中这个内核侧缓存陈旧的坑。先删再拷，让每次构建都是一个全新的
# inode，从根源避开这个问题(跟上面这次会话另外给 media-control 加的 rm -f 是
# 同一类修法，那边最初是为了绕开只读权限，这里主要是为了这个签名信任缓存问题)。
rm -f "$APP_DIR/Contents/Resources/collector"
cp "$FAT_DIR/collector" "$APP_DIR/Contents/Resources/collector"
# 2026-08-06:collector 现在必须在这里显式补签。以前这份是 `go build` 的产物原样拷进来、
# 自带工具链盖的 ad-hoc 签名,所以下面只做 `codesign -v` 验证;改成 universal 之后中间多了
# 一步 lipo,而 lipo 会让原有签名失效(实测:合并后的文件 `codesign -v` 直接不通过),
# 只验证会被 set -e 拦腰打断。签名必须在 lipo 之后做,顺序不能反。
codesign --force --sign - "$APP_DIR/Contents/Resources/collector"

# 端上歌词翻译小助手。collector(Go)调不了 Apple 的 Translation 框架,所以拆成这个独立的
# Swift 可执行文件,由 collector 按自身可执行文件的相对路径调起 —— 跟 media-control 同一
# 个形态。先删再拷再补签的三步跟上面 collector 一模一样,理由见那段注释(lipo 会让签名
# 失效 + 覆盖同 inode 容易踩内核签名缓存)。
rm -f "$APP_DIR/Contents/Resources/lyrics-translate"
cp "$FAT_DIR/lyrics-translate" "$APP_DIR/Contents/Resources/lyrics-translate"
codesign --force --sign - "$APP_DIR/Contents/Resources/lyrics-translate"

# 2026-07-24:QQ 音乐支持——QQ音乐.app 没有 AppleScript 支持(sdef/NSAppleScriptEnabled
# 都核实过没有),读它的播放状态改走系统级 MediaRemote,经 ungive/media-control
# (BSD-3-Clause 开源,https://github.com/ungive/media-control)读。这个工具不是单个
# 独立二进制——`media-control` 可执行文件靠相对路径(`../lib/media-control/
# mediaremote-adapter.pl`)找同一次 Homebrew 安装里的 Perl 适配脚本,脚本再调同一棵树下
# 的 MediaRemoteAdapter.framework 去访问私有框架(实测坐实:只拷可执行文件本身,运行时
# 会报 "Can't open perl script ... No such file or directory")。因此这里把 Homebrew
# Cellar 里 bin/+lib/+Frameworks/ 这一整棵相对路径子树原样搬进
# Contents/Resources/media-control/(排除 INSTALL_RECEIPT.json 等安装元数据),保持它
# 内部的相对路径结构不变——collector 常驻进程按跟自己同目录的固定子路径找
# media-control/bin/media-control(见 lyrimuse-collector/system.go 的
# mediaControlBinaryPath),Swift 侧走 Bundle.main.resourcePath 拼同一条路径——两边都
# 不需要用户自己额外 brew install 任何东西。
#
# 本地开发机上不要求提前手动 `brew install media-control`——下面检测到没装会自动装一次
# (CI 见 release.yml,跑在 GitHub Actions 的 macOS runner 上,提前显式装过,这里的自动
# 安装对 CI 是无操作的冗余检查,不影响什么)。`brew install` 失败(网络问题/没装 Homebrew
# 本身等)不阻断整个构建,跳过这一步、打个警告——QQ 音乐支持是可选功能,不该让完全不需要
# 它的人连 Apple Music 都构建不出来。
MEDIA_CONTROL_PREFIX="$(brew --prefix media-control 2>/dev/null)"
if [ ! -x "$MEDIA_CONTROL_PREFIX/bin/media-control" ] && command -v brew >/dev/null 2>&1; then
  echo "==> media-control not found, installing via Homebrew (QQ 音乐支持)"
  brew install media-control || echo "!! brew install media-control 失败——继续构建,QQ 音乐支持这次不可用,Apple Music 不受影响" >&2
  MEDIA_CONTROL_PREFIX="$(brew --prefix media-control 2>/dev/null)"
fi
if [ -x "$MEDIA_CONTROL_PREFIX/bin/media-control" ]; then
  # 先删再拷贝(跟 collector/.lproj 同款先例):Homebrew Cellar 里这些文件很多是只读的
  # (-r-xr-xr-x),`cp -R` 会原样带过来只读位——第二次往后重新构建时,已存在的只读文件/
  # 目录会让 `cp`/`codesign` 直接 "Permission denied"(实测坐实)。
  rm -rf "$APP_DIR/Contents/Resources/media-control"
  mkdir -p "$APP_DIR/Contents/Resources/media-control"
  cp -R "$MEDIA_CONTROL_PREFIX/bin" "$APP_DIR/Contents/Resources/media-control/bin"
  cp -R "$MEDIA_CONTROL_PREFIX/lib" "$APP_DIR/Contents/Resources/media-control/lib"
  cp -R "$MEDIA_CONTROL_PREFIX/Frameworks" "$APP_DIR/Contents/Resources/media-control/Frameworks"
  chmod -R u+w "$APP_DIR/Contents/Resources/media-control"
  # media-control 这个可执行文件本身完全没签名(实测 `codesign -dv` 报 "code object is
  # not signed at all")——跟 collector(go build 的产物自带签名)不一样,这里需要主动
  # 补签,不然可能被 Gatekeeper 拦下来。MediaRemoteAdapter.framework 内部那个 Mach-O
  # 已经带着 Homebrew 自己的 ad-hoc 签名,不需要(也不应该)重复处理;
  # mediaremote-adapter.pl 是纯文本 Perl 脚本,同样不需要签名。
  codesign --force --sign - "$APP_DIR/Contents/Resources/media-control/bin/media-control"
  # 2026-08-06:universal 构建时把 x86_64 那半也 lipo 进来。
  #
  # Homebrew 在 Apple Silicon 上只会装 arm64 那份,而且不让你拉异架构 bottle
  # (`brew fetch --bottle-tag=sonoma media-control` 直接回 "Bottle for tag :sonoma is
  # unavailable",实测)。所以 Intel 那半得自己取:media-control 在官方 homebrew-core 里,
  # bottle 放在 ghcr.io,可以拿 formula JSON 里记录的 sha256 直接下对应 blob(匿名 token
  # 就是字面量 "QQ==" —— Homebrew 自己访问 ghcr 用的也是这个),下完**先校验 sha256 再
  # 解包**,不无条件信任下载内容。Intel 的 bottle tag 就是不带 arm64_ 前缀的那个 macOS
  # 代号(现在是 sonoma),所以这里按"排除 arm64_* 和 *_linux"动态挑,而不是写死 sonoma。
  #
  # 只有两个 Mach-O 需要合并(逐文件核实过):框架里的 MediaRemoteAdapter 和 lib/ 下的
  # MediaRemoteAdapterTestClient。bin/media-control 本身是 Perl 脚本(`file` 报
  # "Perl script text executable"),没有架构这回事。
  #
  # 版本必须两边完全一致才合并 —— 把 0.7.6 的 arm64 切片和别的版本的 x86_64 切片拼进
  # 同一个文件,属于"看着能跑、两个架构行为却不一定一样"的坑,宁可不合并、只报警告。
  #
  # 合并完必须重签框架:lipo 会让原签名失效(实测合并后 codesign -v 不通过)。签的是整个
  # .framework 包而不是里面那个 Mach-O —— 包里有 _CodeSignature/CodeResources,只重签
  # 内层二进制会留下一份对不上的资源清单。
  #
  # 这一步失败不阻断构建,跟上面"没装 media-control 就跳过"同一个策略(QQ 音乐支持是可选
  # 功能,不该让不需要它的人连 Apple Music 都构建不出来)。代价是那次产物在 Intel 上没有
  # QQ 音乐支持,所以下面的架构自检会把还是单架构的文件列出来。
  if [ "$UNIVERSAL" = 1 ]; then
    MC_FW="$APP_DIR/Contents/Resources/media-control/Frameworks/MediaRemoteAdapter.framework"
    MC_VER="$(brew list --versions media-control | awk '{print $2}')"
    MC_META="$(curl -fsS https://formulae.brew.sh/api/formula/media-control.json | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
files = d["bottle"]["stable"]["files"]
cand = [t for t in files if not t.startswith("arm64_") and not t.endswith("_linux")]
print(cand[0], files[cand[0]]["sha256"], d["versions"]["stable"]) if cand else print("")
' || true)"
    MC_TAG="$(echo "$MC_META" | awk '{print $1}')"
    MC_SHA="$(echo "$MC_META" | awk '{print $2}')"
    MC_API_VER="$(echo "$MC_META" | awk '{print $3}')"
    if [ -z "$MC_SHA" ]; then
      echo "!! media-control 没有 Intel bottle(只有 arm64)——x86_64 上 QQ 音乐支持不可用" >&2
    elif [ "$MC_VER" != "$MC_API_VER" ]; then
      echo "!! media-control 本机版本 $MC_VER 与 formula 当前版本 $MC_API_VER 不一致,跳过 lipo(先 brew upgrade media-control)" >&2
    else
      MC_TGZ="$FAT_DIR/media-control-x86_64-$MC_API_VER.tar.gz"
      if curl -fsSL -H "Authorization: Bearer QQ==" \
           "https://ghcr.io/v2/homebrew/core/media-control/blobs/sha256:$MC_SHA" -o "$MC_TGZ" \
         && [ "$(shasum -a 256 "$MC_TGZ" | awk '{print $1}')" = "$MC_SHA" ]; then
        MC_X86="$FAT_DIR/media-control-x86_64"
        rm -rf "$MC_X86"; mkdir -p "$MC_X86"
        tar -xzf "$MC_TGZ" -C "$MC_X86"
        # bottle 解出来是 media-control/<版本>/... 这层结构,用 find 定位而不是拼路径。
        MC_X86_ROOT="$(find "$MC_X86" -type d -name "Frameworks" -maxdepth 3 | head -1)"
        MC_X86_ROOT="$(dirname "${MC_X86_ROOT:-$MC_X86}")"
        merged=0
        for rel in "Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
                   "lib/media-control/MediaRemoteAdapterTestClient"; do
          dst="$APP_DIR/Contents/Resources/media-control/$rel"
          src="$MC_X86_ROOT/$rel"
          if [ -f "$dst" ] && [ -f "$src" ]; then
            lipo -create "$dst" "$src" -output "$dst.fat" && mv "$dst.fat" "$dst"
            merged=$((merged + 1))
          fi
        done
        if [ "$merged" -gt 0 ]; then
          codesign --force --sign - "$MC_FW"
          codesign --force --sign - "$APP_DIR/Contents/Resources/media-control/lib/media-control/MediaRemoteAdapterTestClient" 2>/dev/null || true
          echo "    media-control x86_64 切片已合入($merged 个 Mach-O, bottle tag=$MC_TAG)"
        else
          echo "!! media-control x86_64 bottle 里没找到预期的 Mach-O,跳过 lipo" >&2
        fi
      else
        echo "!! media-control x86_64 bottle 下载或校验失败,跳过 lipo——x86_64 上 QQ 音乐支持不可用" >&2
      fi
    fi
  fi
  echo "    media-control bundled (QQ 音乐支持)"
else
  # ⚠️ 2026-08-31 暂存化连带出来的一个坑,不补会**静默降级用户已经装好的包**:
  # 就地组装的年代,brew 里找不到 media-control 时上面那句 `rm -rf` 在 if 内、不会执行,
  # 旧的 media-control 原样留在包里,这次构建等于"没动它"。换成暂存包之后,整个
  # Contents/Resources/media-control 子树压根不存在,swap 就会拿一个**丢了 QQ 音乐支持的
  # 包**覆盖掉本来完好的安装,而且只有一句 warning、退出码还是 0。
  # 所以这里显式从现装包继承一份,把那层隐性兜底补回来。
  # ⚠️ 必须在下面 codesign 之前做 —— 签完再往包里塞文件会破坏签名封印。
  if [ -n "$STAGE" ] && [ -d "$FINAL_APP_DIR/Contents/Resources/media-control" ]; then
    ditto "$FINAL_APP_DIR/Contents/Resources/media-control" "$APP_DIR/Contents/Resources/media-control"
    echo "    media-control 从现装包继承(brew 里没找到,保持已装版本不被降级)"
  fi
  echo "!! media-control not found (brew install media-control) — QQ 音乐支持这次构建不可用,Apple Music 不受影响" >&2
fi

# 2026-07-23:检查更新改接 Sparkle(见 UpdateChecker.swift 的替代——那份手写的
# "查 GitHub API+弹 Alert"逻辑已删,改用这个 macOS 生态里事实标准的自动更新框架)。
# `swift build` 不会自动把这个 SPM 二进制依赖(binaryTarget,一个预编译的
# Sparkle.xcframework)嵌入 .app bundle,要手动完成三件事,踩坑记录见几个真实项目的
# Sparkle 集成笔记(比如 DanieliusIsiunas/drobu 的 sparkle-macos-gotchas.md):
# 1) 用 ditto 而不是 cp -R 拷贝——Sparkle.framework 内部用了符号链接
#    (Versions/Current -> B),cp -R 会把符号链接拆开变成实体拷贝,进而破坏代码签名。
# 2) 给主执行文件加 @executable_path/../Frameworks 这个 rpath,不然运行时 dyld
#    找不到这个 framework。
# 3) inside-out 签名:framework 内部的 Autoupdate/Updater.app/两个 XPC service 各自
#    先签,再签 framework 整体本身——不能用 --deep,也不要给这些子组件传
#    --entitlements(只有最外层 .app 才需要)。下面这行的最终 `codesign -s - --force
#    --identifier "$LABEL" "$APP_DIR"` 本来就没加 --deep,不会覆盖这里已经各自
#    签过的 Sparkle 组件。
#
# 用 find 动态定位 xcframework 里的 slice 路径(而不是硬编码 macos-arm64_x86_64
# 这个字符串)——SPM/Sparkle 版本更新时这层目录名可能变,find 对这类改动更稳。
SPARKLE_FW_SRC=$(find .build/artifacts/sparkle -type d -name "Sparkle.framework" -path "*/Sparkle.xcframework/*" 2>/dev/null | head -1)
if [ -z "$SPARKLE_FW_SRC" ]; then
  echo "!! Sparkle.framework not found under .build/artifacts — did 'swift package resolve' run?" >&2
  exit 1
fi
mkdir -p "$APP_DIR/Contents/Frameworks"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_FW_SRC" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
# 目标不是 universal 时,Sparkle 也要瘦到目标架构。它是预编译的 universal xcframework
# (macos-arm64_x86_64),不瘦的话主包里照样躺着 x86_64 代码 —— 而"包里含 Intel 代码"正是
# 那条 macOS 告警的触发条件,主包 arm64-only 的意义就没了。瘦完签名必然失效,所以放在下面
# 本来就有的 inside-out 签名之前,由那几行一并重签。
if [ "$UNIVERSAL" = 0 ]; then
  while IFS= read -r f; do
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    case "$archs" in
      *" "*) lipo -thin "$ARCHES" "$f" -output "$f.thin" && mv "$f.thin" "$f" ;;
    esac
  done < <(find "$APP_DIR/Contents/Frameworks/Sparkle.framework" -type f)
  echo "    Sparkle.framework thinned to $ARCHES"
fi
# -add_rpath 在这个 rpath 已经存在时会报错退出(比如第二次跑这个脚本)——用
# otool -l 先查一遍,已经有了就跳过,保持这一步幂等。
if ! otool -l "$BIN" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
fi
find "$APP_DIR/Contents/Frameworks/Sparkle.framework" \
    \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
    -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP_DIR/Contents/Frameworks/Sparkle.framework"
echo "    Sparkle.framework embedded + signed"
# 2026-07-21:本地化文案 + 状态栏图标直接从源码拷进 Contents/Resources/，不再依赖
# SwiftPM 的 Bundle.module 访问器——原因见下面这段注释和 L10n.swift/MenuBarMenu.swift
# 顶部注释。AppIcon.icns 已经证明 Contents/Resources/ 这个位置对 codesign 完全安全。
#
# 2026-07-21 当天另一次实测坐实的坑:`cp -R src dst` 在 dst 已经存在时会把 src 整个
# 拷成 dst 下面的一个子目录(dst/src),而不是拿 src 的内容去覆盖 dst 本身——第一次
# build.sh 跑的时候 en.lproj/zh-hans.lproj 还不存在,拷贝行为正常;从第二次往后,
# Contents/Resources/{en,zh-hans}.lproj 已经是已存在的目录,每次重新构建都会在它
# 下面多嵌一层 en.lproj/en.lproj、越嵌越深,而真正被读取的还是最外层那份第一次构建
# 时的旧文案——新加的翻译永远生效不了,且不会有任何报错(App 里表现成"这个字符串一直
# 显示中文原文",很容易被误判成 L10n 查找逻辑或者 SwiftUI 刷新的问题,实际上是这里)。
# 先删再拷贝,保证每次都是干净覆盖,不会残留/嵌套旧内容。
rm -rf "$APP_DIR/Contents/Resources/zh-hans.lproj" "$APP_DIR/Contents/Resources/en.lproj"
cp -R Sources/lyrimuse/Resources/zh-hans.lproj "$APP_DIR/Contents/Resources/zh-hans.lproj"
cp -R Sources/lyrimuse/Resources/en.lproj "$APP_DIR/Contents/Resources/en.lproj"
cp Sources/lyrimuse/Resources/MenuBarIconTemplate.png "$APP_DIR/Contents/Resources/MenuBarIconTemplate.png"
cp Sources/lyrimuse/Resources/ListenBrainzIcon.png "$APP_DIR/Contents/Resources/ListenBrainzIcon.png"
# 第三方许可证全文随 .app 一起分发。这不是可选的礼貌:打进来的 media-control /
# mediaremote-adapter 是 BSD-3-Clause,Sparkle 和 KeyboardShortcuts 是 MIT,三者的
# 二进制分发条款都要求随附版权声明与许可证文本。仓库根那份是唯一来源,这里只拷。
cp ../THIRD_PARTY_LICENSES "$APP_DIR/Contents/Resources/THIRD_PARTY_LICENSES"
cp Sources/lyrimuse/Resources/LastfmIcon.png "$APP_DIR/Contents/Resources/LastfmIcon.png"
cp Sources/lyrimuse/Resources/YouTubeMusicIcon.png "$APP_DIR/Contents/Resources/YouTubeMusicIcon.png"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>lyrimuse</string>
    <key>CFBundleIdentifier</key>
    <string>${LABEL}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Lyrimuse</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 「发现新播放器」那条通知带两个按钮(加入信任列表/忽略),而默认的 banner 样式
         5 秒就自动消失、按钮要悬停才露出来。alert 样式常驻不走、按钮直接可见。
         这是 legacy NSUserNotification 时代的键、只决定该 App 通知样式的**初始默认值**
         (用户在系统设置里改过就以他的为准);对现代 UNUserNotificationCenter 是否仍生效
         没有实测坐实,成本近乎零所以加上 —— 最坏情况是个 no-op。
         ⚠️ 本地通知不需要任何其它 Info.plist 键,也不需要 entitlements。 -->
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
    <!-- 2026-07-23 实测坐实：这个 key 缺失时,OnboardingView 第一步"请求权限"按钮
         调 MusicAutomationPermission.check(askIfNeeded: true)在全新安装的机器上
         (TCC 数据库对这个 App 完全没有历史记录)系统直接静默拒绝弹出授权对话框、
         点了没反应——这台开发机上一直正常是因为本机 TCC 数据库里早就攒下了这个
         App 改名前后各个身份的历史授权记录，把"首次全新请求"这条路径的真实缺陷
         盖住了，只有在没有任何历史记录的全新机器上才会暴露。Apple 官方要求任何
         要发 Apple Event 控制别的 App 的进程,必须在 Info.plist 里声明这个 key
         说明用途,这段文字会原样显示在系统弹窗里,不经过 App 自己的 L10n 机制。 -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Lyrimuse needs to send Apple Events to media players and browsers to read the currently playing track and show synced lyrics.</string>
    <!-- 2026-07-29 新增:给"连接 Last.fm 账号"这一步的浏览器授权做自动回跳用
         (见 LastfmAuthFlow.authorizeURL 的 cb= 参数 + AppDelegate 的 GetURL 事件
         处理)——注册这个 scheme 之后,授权页跳转到 lyrimuse://lastfm-auth-callback
         会被系统路由回这个 App,不需要用户自己回来点"我已完成授权,继续"。 -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${LABEL}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>lyrimuse</string>
            </array>
        </dict>
    </array>
    <key>SUFeedURL</key>
    <string>https://github.com/Yudaotor/lyrimuse/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>xTGKkA2z7gn42F0oyb6Qe4YyL+G/RTsKu5jvvsfytTE=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <!-- "自动检查更新"开着才有意义的下一档:自动下载并安装,不用每次弹窗等用户点"安装"。
         2026-08-31 用户要求默认开启。这两个键都只是**默认值**——跟 SUEnableAutomaticChecks
         同一个道理,用户在设置页手动改过之后,Sparkle 自己持久化在 UserDefaults 里的那份
         (SUAutomaticallyUpdate)说了算,不会被这里的默认值覆盖回去,见
         SparkleUpdaterManager.swift 的注释。 -->
    <key>SUAutomaticallyUpdate</key>
    <true/>
</dict>
</plist>
PLIST

# 2026-07-18 曾经实测坐实过：SwiftPM 给每个声明了 resources 的 target 生成的
# Bundle.module 访问器，查找资源包时走的是
# Bundle.main.bundleURL.appendingPathComponent("<target>_<target>.bundle")——对一个
# 真正的 .app 来说 Bundle.main.bundleURL 是这个 .app 包本身的根目录(跟 Contents/ 同
# 级)，把资源包原样搬到这个位置会导致 codesign 直接拒签("unsealed contents present
# in the bundle root")。当时的应对是"干脆不搬，让 Bundle.module 走它自己那条写死
# 指向这台开发机 .build/.../release/ 的兜底路径"——但这意味着别的机器打开这个 App
# (不管是自己 clone 源码构建，还是以后下载预编译包)几乎必然在第一次访问 Bundle.module
# 时 fatalError 崩溃(fatalError 不可捕获，这个坑当时被记录下来但没有真的解决)。
#
# 2026-07-21 起正确修复：Contents/Resources/ 才是 codesign 认可的标准资源位置(跟
# AppIcon.icns 用的是同一个目录，从来没出过问题)，不是 bundle 根目录——上面几行已经
# 把 .lproj/图标直接拷到这里，L10n.swift/MenuBarMenu.swift 也已经改成用 Bundle.main
# 查找，不再触碰 Bundle.module，从根源上消除了这个崩溃风险。

# 主动 ad-hoc 签名(而不是只验证):Apple Silicon 上 AMFI 强制签名，工具链链接时已经
# 自动盖过章，这一步是幂等的空操作；Intel Mac 上没有这层强制，工具链历史上不会自动
# 签，若只做 `codesign -v` 验证会在这里直接报"未签名"、被 set -e 拦腰打断整个脚本
# (2026-07-17 审计发现。这台机器没有物理 Intel Mac，但 2026-07-18 交叉编译了一份
# `swift build --arch x86_64` 产物直接验证过：codesign -v 确实报
# "code object is not signed at all"，补签 `codesign -s - --force` 后签名有效，
# 用 Rosetta 也能正常跑起来——不是纯理论推测，不管哪种架构都能过关)。
#
# --identifier 固定成这个 launchd label 同款字符串，不让 codesign 自己按内容生成
# identifier——2026-07-18 加自动化权限(Automation)功能时实测坐实：不传 --identifier，
# codesign 会按二进制编译出的内容自动生成一串"desktop-lyrics-<hash>"式 identifier，
# 内容真的变了(哪怕只是加一行代码)hash 就跟着变，而 TCC 的自动化权限授权记录是按
# 这个 identifier 认的——意味着不固定的话，每次有实质代码改动的正式发布都会让系统
# 认成一个"新 App"，之前用户点过的"允许"授权会失效、下次用到时又要重新弹一次系统
# 授权对话框。显式传 --identifier 之后实测验证过：哪怕改代码重新构建，identifier 也
# 保持不变(只跟这个参数本身有关，不再按内容重算)。这次改成对整个 .app 包签名(而不是
# 只签裸可执行文件)——TCC 认的是这份签名，2026-07-18 真机实测坐实：即使 identifier
# 字符串不变，从裸可执行文件迁移到 .app 包这次代码结构本身发生了变化，系统确实没有认成
# 同一个 App，自动化权限(控制 Music.app 播放)重新弹了一次系统授权对话框——这是这次
# 迁移唯一一次性的代价，同意一次之后往后重新构建/重启都不会再弹。
codesign -s - --force --identifier "$LABEL" "$APP_DIR"
codesign -v "$APP_DIR" && echo "    signature valid"
# collector 已经在上面 lipo 之后显式 ad-hoc 签过一次(见那一步的注释:lipo 会让 go build
# 产物自带的那份签名失效,所以不能再像以前那样只验证不签)——最外层这行 codesign 没加
# --deep，只签 .app 这一个代码对象，不会动内层这个独立二进制自己的签名；这里显式验证
# 一遍，而不是假设。
codesign -v "$APP_DIR/Contents/Resources/collector" && echo "    collector signature valid"

# 架构自检:把包里每个 Mach-O 的架构列出来,并在"要求 universal 却有文件只剩一个架构"时
# 明确报出来。加这一步的直接原因是 v1.0.0~v1.2.0 三个版本都在没人察觉的情况下发成了
# arm64-only —— 光靠"记得传参数"不够,产物本身要能自证。
# 架构自检:两个方向都查。缺目标架构要报(universal 包少一半就白做了);多出目标之外的架构
# 同样要报 —— 主包多带一份 x86_64 就会踩那条 macOS 告警。加这一步的直接原因是
# v1.0.0~v1.2.0 三个版本都在没人察觉的情况下发成了 arm64-only:光靠"记得传参数"不够,
# 产物本身要能自证。用 find -type f(不加 -perm)以免漏掉没有执行位的 Mach-O。
echo "==> architecture check [$ARCHES]"
ARCH_BAD=""
while IFS= read -r f; do
  archs="$(lipo -archs "$f" 2>/dev/null || true)"
  [ -z "$archs" ] && continue # 脚本/资源文件,没有架构这回事
  printf "    %-56s %s\n" "${f#$APP_DIR/}" "$archs"
  for want in $ARCHES; do
    case " $archs " in *" $want "*) ;; *) ARCH_BAD="$ARCH_BAD ${f#$APP_DIR/}(缺$want)" ;; esac
  done
  for got in $archs; do
    case " $ARCHES " in *" $got "*) ;; *) ARCH_BAD="$ARCH_BAD ${f#$APP_DIR/}(多余$got)" ;; esac
  done
done < <(find "$APP_DIR" -type f)
if [ -n "$ARCH_BAD" ]; then
  echo "!! 架构与目标[$ARCHES]不符:" >&2
  for f in $ARCH_BAD; do echo "     $f" >&2; done
  echo "!! 要发布的构建先解决上面这些(package.sh 会硬拦)" >&2
fi

# ==> 把暂存包一次性换进 /Applications(2026-08-31,见文件上方 FINAL_APP_DIR 那段注释)。
#
# 用 APFS 的 renamex_np(RENAME_SWAP) 而不是 `mv`,两个原因:
#   1. **`mv 新 旧` 在旧目录已存在时不是覆盖、是塞进去**,而且退出码 0、没有任何输出 ——
#      实测:`mv new old` 之后 old/Contents 一个字节没变,只是多出一个 old/new 子目录。
#      套到这里就是 /Applications/Lyrimuse.app/Lyrimuse.app,旧包原封不动、脚本报成功,
#      表现是"装完了但行为没变",比直接报错难查得多。`set -euo pipefail` 拦不住。
#   2. RENAME_SWAP 是**单次原子 vfs 操作**,没有"App 短暂不存在"的窗口 —— 并发的 launchd /
#      Finder / 正在跑的进程任一时刻看到的要么是完整旧包、要么是完整新包。两步 mv
#      (旧挪走→新挪上)做不到这点,中间那一瞬 /Applications 下没有这个 App。
# 换完之后 $STAGE 指向的是**旧包**,交给上面那个 EXIT trap 删 —— 顺带等于装完才删旧包,
# 老进程在被重启之前一直有完整的一份可用。
# 首装(目标还不存在)时 renamex_np 返回 ENOENT,回退 mv;那条路径上目标不存在,没有嵌套风险。
if [ -n "$STAGE" ]; then
  if [ -e "$FINAL_APP_DIR" ]; then
    /usr/bin/python3 - "$STAGE" "$FINAL_APP_DIR" <<'SWAP'
import ctypes, sys
libc = ctypes.CDLL("/usr/lib/libSystem.dylib", use_errno=True)
libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
RENAME_SWAP = 0x00000002
if libc.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), RENAME_SWAP) != 0:
    import os
    sys.exit(f"renamex_np(RENAME_SWAP) failed: {os.strerror(ctypes.get_errno())}")
SWAP
  else
    mv "$STAGE" "$FINAL_APP_DIR"
  fi
  # ⚠️ 必须重指回真实路径。下面 restart 段的 `pgrep -f "$BIN"`(三处)和
  # `pgrep -f "$APP_DIR/Contents/Resources/collector"` 匹配的是进程命令行,那是
  # /Applications/... —— 忘了这两行就会永远判定"没起来"然后 exit 1。
  # `open "$APP_DIR"` 同理,不重指就会去打开那个暂存包。
  APP_DIR="$FINAL_APP_DIR"
  BIN="$APP_DIR/Contents/MacOS/lyrimuse"
  echo "==> installed → $FINAL_APP_DIR"
fi

if [ "$NO_RESTART" = 1 ]; then
  echo "==> built (restart skipped)"
  exit 0
fi

PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
if launchctl list "$LABEL" >/dev/null 2>&1; then
  # 开机启动开关已经在菜单里打开过、这份 job 归 launchd 管——用 kickstart 让 launchd
  # 用新构建的二进制重启同一个受管进程，不要另外手动 kill+起一个游离进程，否则会变成
  # "launchd 记录里的进程死了、外面又跑着一个 launchd 不认识的新进程"这种双实例混乱
  # (实测踩过这个坑)。
  echo "==> restarting via launchd (kickstart)"
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  sleep 2
  if ! pgrep -f "$BIN" >/dev/null 2>&1; then
    # kickstart 有时会静默失败——launchd 给这个 job 缓存了上一次运行遗留的 LWCR
    # (Lightweight Code Requirement)codesigning 约束，绑定的是旧二进制的 cdhash；
    # release 每次重新 ad-hoc 签名，cdhash 必然变化，kickstart 本身不会刷新这个约束，
    # 新二进制会被 OS 直接拒绝启动。只有完整卸载再重新加载这个 job，才会让 launchd
    # 丢掉旧约束、重新从 plist/二进制读起(实测坐实过这个失败模式和这个修法)。
    echo "==> kickstart produced no running process, retrying via bootout+bootstrap"
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    # bootout 是异步的，launchd 需要一点时间才会真正把这个 job 卸载干净——紧接着就
    # bootstrap 同一个 label 有时会因为卸载还没完成而失败/静默无效(实测坐实：不加
    # 这个间隔时，这条自愈分支本身也会偶尔失败，需要手动再重试一遍才行)。
    sleep 1
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    sleep 1
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
  fi
else
  if pid=$(pgrep -f "$BIN" 2>/dev/null); then
    echo "==> stopping running instance (pid $pid)"
    kill "$pid"
    sleep 1
  fi
  echo "==> launching"
  open "$APP_DIR"
fi
sleep 2
if pid=$(pgrep -f "$BIN"); then
  echo "==> Lyrimuse running, pid $pid"
else
  echo "!! Lyrimuse not running — check ~/Library/Logs/lyrimuse.log" >&2
  exit 1
fi

# collector 是独立的一份 launchd job(com.lyrimuse.collector),上面那一整套 kickstart/
# bootout 只管 $LABEL 这个 App job，从来没管过它 —— 而这个脚本每跑一次，都会把
# Resources/collector 删掉重拷、再 `codesign --force --sign -` 重签一遍(见上面那一步)，
# cdhash 必然变。于是:
#
#   1. 正在跑的老 collector 因为二进制被换掉，下次缺页时被 SIGKILL;
#   2. launchd(KeepAlive=true)想拉起新的，但它给这个 job 缓存的 LWCR
#      (Lightweight Code Requirement)还绑在旧 cdhash 上 —— 新二进制被内核直接拒绝，
#      崩溃报告里写得很明白:CODESIGNING / "Launch Constraint Violation" +
#      SIGKILL (Code Signature Invalid)，launchctl 那边则是 exit 78 EX_CONFIG、
#      job state = spawn failed;
#   3. KeepAlive 会一直重试一直失败(2026-08-10 实测抓到时 runs 已经 127 次)，
#      collector 就此永久躺平 —— 歌词解析、scrobble、relay 全停，而 App 本身活得好好的，
#      表现成"这首歌一直没歌词、歌词管理也没条目"，极难联想到是构建脚本干的。
#
# 所以这里不先试 kickstart:App 那边 kickstart 只是"有时"失败，collector 这边是**每次构建
# 必然**失效，直接走完整的卸载重装。中间那个 sleep 跟上面同理 —— bootout 是异步的。
COLLECTOR_LABEL="com.lyrimuse.collector"
COLLECTOR_PLIST="$HOME/Library/LaunchAgents/$COLLECTOR_LABEL.plist"
if [ -f "$COLLECTOR_PLIST" ]; then
  echo "==> reloading collector job (refreshing its launch constraint)"
  launchctl bootout "gui/$(id -u)/$COLLECTOR_LABEL" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$COLLECTOR_PLIST" 2>/dev/null || true
  sleep 1
  launchctl kickstart -k "gui/$(id -u)/$COLLECTOR_LABEL" 2>/dev/null || true
  sleep 2
  if cpid=$(pgrep -f "$APP_DIR/Contents/Resources/collector"); then
    echo "==> collector running, pid $cpid"
  else
    # 不 exit 1:App 本身已经起来了，collector 没起来是个独立故障，值得刺眼但不该让
    # 整个构建被判失败(而且这条分支真出现时，多半要人去看崩溃报告)。
    echo "!! collector not running — launchctl print gui/$(id -u)/$COLLECTOR_LABEL" >&2
  fi
fi

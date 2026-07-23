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
#   ./build.sh              构建 + 重启(如果当前有实例在跑)
#   ./build.sh --no-restart 只构建
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse/
APP_NAME="Lyrimuse"
# X.Y.Z 语义化版本——检查更新功能(UpdateChecker.swift)靠 CFBundleShortVersionString
# 跟 GitHub Release 的 tag(去掉 v 前缀)比大小,必须是干净的三段数字,不能再是本地
# 手动构建这边一直硬编码的"1.0"。CI(release.yml)在真正打 tag 触发时会传入
# LYRIMUSE_VERSION 环境变量(从 tag 解析出的真实版本号);本地手动跑不设这个变量,
# 用占位默认值——本地构建本来就不是要发布的正式版本,不需要精确。
APP_VERSION="${LYRIMUSE_VERSION:-1.0.0}"
# 装到 /Applications/ 而不是仓库自己的 bin/ 里(2026-07-18 当天改的——一开始装在 bin/
# 下,用户把它拖/拷到了 /Applications/ 自己启动,导致真正在跑的是一份没同步过后续几次
# 修复的旧拷贝,重新构建/重启了好几次都没反映到用户实际在看的那个进程上,排查了很久才
# 发现。/Applications/ 才是这个 App 实际使用的位置,以后 build.sh 直接装到这里，不再
# 留一份 bin/ 下的拷贝，避免"到底哪份是真的在跑"这种混乱再发生一次)。
APP_DIR="/Applications/${APP_NAME}.app"
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
RELEASE_DIR=".build/release"

echo "==> building (release)"
swift build -c release

# 2026-07-21:collector 现在打包进 .app 里(见 Contents/Resources/collector),不再要求
# 用户手动单独构建它——CollectorServiceManager.swift 靠 Bundle.main.bundleURL 精确知道
# 它在哪，跟 LoginItemManager 认自己的方式一样。跟 lyrimuse-collector/build.sh 同款
# GOTOOLCHAIN=go1.24.4(系统 Go 1.21 产出的二进制缺 LC_UUID，AMFI 拒签，见那份脚本的
# 注释)。
echo "==> building collector"
(cd ../lyrimuse-collector && GOTOOLCHAIN=go1.24.4 go build -o "$OLDPWD/$RELEASE_DIR/collector" .)

echo "==> assembling .app bundle"
# CFBundleIdentifier 这次(2026-07-20 改名 Lyrimuse)跟上面的 $LABEL 统一成同一个
# 字符串——早先(2026-07-18 打包成 .app 那次)故意让两者不同,是因为 CFBundleIdentifier
# 需要继续等于裸可执行文件时代 UserDefaults.standard 隐式落的偏好域名"desktop-lyrics"、
# 才能让新打包的 .app 无缝接上旧设置。这次是主动做一次完整改名,旧的 UserDefaults 数据
# 已经用一次性脚本从"desktop-lyrics"域迁移到新域,不再需要靠"保持 CFBundleIdentifier
# 不变"这个手段来保护旧设置,直接统一成标准的反向域名写法。
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$RELEASE_DIR/lyrimuse" "$BIN"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# collector 装在 Resources/ 而不是 MacOS/——那里是 CFBundleExecutable 指向的主执行文件，
# collector 是被 launchd 单独拉起的后台辅助二进制，不是这个 App 自己的入口。
cp "$RELEASE_DIR/collector" "$APP_DIR/Contents/Resources/collector"

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
    <!-- 2026-07-23 实测坐实：这个 key 缺失时,OnboardingView 第一步"请求权限"按钮
         调 MusicAutomationPermission.check(askIfNeeded: true)在全新安装的机器上
         (TCC 数据库对这个 App 完全没有历史记录)系统直接静默拒绝弹出授权对话框、
         点了没反应——这台开发机上一直正常是因为本机 TCC 数据库里早就攒下了这个
         App 改名前后各个身份的历史授权记录，把"首次全新请求"这条路径的真实缺陷
         盖住了，只有在没有任何历史记录的全新机器上才会暴露。Apple 官方要求任何
         要发 Apple Event 控制别的 App 的进程,必须在 Info.plist 里声明这个 key
         说明用途,这段文字会原样显示在系统弹窗里,不经过 App 自己的 L10n 机制。 -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Lyrimuse needs to send Apple Events to Music.app to read the currently playing track and show synced lyrics.</string>
    <key>SUFeedURL</key>
    <string>https://github.com/Yudaotor/lyrimuse/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>xTGKkA2z7gn42F0oyb6Qe4YyL+G/RTsKu5jvvsfytTE=</string>
    <key>SUEnableAutomaticChecks</key>
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
# collector 自己在 go build 那一步已经原生签过一次(GOTOOLCHAIN=go1.24.4 的产物自带签名)——
# 上面这行没加 --deep，只签外层 .app 这一个代码对象，理论上不会动内层这个独立二进制自己的
# 签名；这里显式验证一下，而不是假设。
codesign -v "$APP_DIR/Contents/Resources/collector" && echo "    collector signature valid"

if [ "${1:-}" = "--no-restart" ]; then
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

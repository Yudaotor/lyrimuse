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

cd "$(dirname "$0")" # desktop-lyrics/
# 2026-07-20:App 的正式名字定为 Lyrimuse(lyric + muse)——这个字符串只驱动
# /Applications/ 下 .app 包的文件夹名 + CFBundleName/CFBundleDisplayName(Finder/
# Dock 上看到的名字)。故意不碰下面的 LABEL(codesign --identifier / launchd
# Label,TCC 自动化权限按这个认)和 Info.plist 里的 CFBundleIdentifier(UserDefaults
# 偏好域按这个认,改了会让已有的语言/字体/颜色/快捷键绑定等设置全部读不到)——这两个
# 是内部身份标识,不需要跟对外的品牌名保持一致,保持不变才能让这次改名对已有安装
# 无缝升级,不产生权限/设置的一次性代价。
APP_NAME="Lyrimuse"
# 装到 /Applications/ 而不是仓库自己的 bin/ 里(2026-07-18 当天改的——一开始装在 bin/
# 下,用户把它拖/拷到了 /Applications/ 自己启动,导致真正在跑的是一份没同步过后续几次
# 修复的旧拷贝,重新构建/重启了好几次都没反映到用户实际在看的那个进程上,排查了很久才
# 发现。/Applications/ 才是这个 App 实际使用的位置,以后 build.sh 直接装到这里，不再
# 留一份 bin/ 下的拷贝，避免"到底哪份是真的在跑"这种混乱再发生一次)。
APP_DIR="/Applications/${APP_NAME}.app"
BIN="$APP_DIR/Contents/MacOS/desktop-lyrics"
LABEL="com.chenyuhao.applemusic-desktop-lyrics"
RELEASE_DIR=".build/release"

echo "==> building (release)"
swift build -c release

echo "==> assembling .app bundle"
# Info.plist 的 CFBundleIdentifier 故意跟上面 codesign 用的 $LABEL 不是同一个字符串——
# 这两者服务两件不同的事,不需要绑在一起:
# - $LABEL(codesign --identifier / launchd Label)决定 TCC 认不认得"这是同一个 App"
#   （自动化权限授权记录按这个认),裸可执行文件时代就已经是这个值,继续沿用。
# - CFBundleIdentifier 决定 UserDefaults.standard 落在哪个偏好域——裸可执行文件没有
#   真正的 Info.plist,`UserDefaults.standard` 当时隐式落在按可执行文件名生成的
#   "desktop-lyrics" 域里;2026-07-18 实测坐实:如果这里填跟 $LABEL 一样的反向域名式
#   identifier,会让 UserDefaults 切到一个全新的偏好域,用户积累的所有设置(语言/字体/
#   颜色/快捷键绑定/悬浮窗样式等等)会被整个孤立在旧域里读不到。显式填成
#   "desktop-lyrics"、跟裸可执行文件时代完全一样,才能让新打包的 .app 无缝接上旧设置,
#   不用另外写一次性迁移逻辑。
#
# 副作用(同样是 2026-07-18 实测坐实,不是理论推测):即使 $LABEL 保持不变,从裸可执行
# 文件迁移到正经 .app 包这次,TCC 依然会把它当成一个新 App，自动化权限(控制 Music.app
# 播放)会重新弹一次系统授权对话框——这是本来就不确定、这次真机验证坐实了的行为，不是
# 迁移哪里没做对。
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$RELEASE_DIR/desktop-lyrics" "$BIN"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>desktop-lyrics</string>
    <key>CFBundleIdentifier</key>
    <string>desktop-lyrics</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Lyrimuse</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
</dict>
</plist>
PLIST

# SwiftPM 给每个声明了 resources 的 target 生成的 Bundle.module 访问器，查找资源包时
# 走的是 Bundle.main.bundleURL.appendingPathComponent("<target>_<target>.bundle")——
# 对一个真正的 .app 来说 Bundle.main.bundleURL 是这个 .app 包本身的根目录(跟 Contents/
# 同级)。2026-07-18 真机实测坐实过一次"把这两个资源包原样搬到包根目录"的方案，结果
# codesign 直接拒签——不是 `codesign -v` 校验警告那么轻，是 `codesign -s` 签名这一步
# 本身就以"unsealed contents present in the bundle root"报错退出(exit 1)，比对
# `codesign -dv` 才发现整个签名操作根本没生效，一直在用上一次(甚至是链接器自动盖的)
# 陈旧签名——真正的坑，不是能靠 --deep 或者给这两个资源包单独先签一遍就绕过去的(两条
# 都实测试过，单独给 bundle 签完再签外层 .app 依然同样报错，根因是"包根目录下不能有
# Contents/ 之外的东西"这条 codesign 规则本身，不是签名先后顺序的问题)。
#
# 所以这里不把这两个资源包搬进 .app：让 Bundle.module 访问器走它自己那条兜底
# 路径——一个写死指向这台开发机 .build/arm64-apple-macosx/release/ 的绝对路径。这是
# 一个有意识接受的取舍，不是偷懒:这个 App 从来没打算发布/搬到别的机器，`.build/` 目录
# 只要还在(每次 build.sh 都会重新生成)这条兜底路径就一直成立，代价是"如果这个仓库被
# clone 到别的机器上打包运行，本地化文案会取不到、可能直接 fatalError"——这台机器上不
# 会发生，如实记录在这里以防以后忘记。

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
  echo "==> desktop-lyrics running, pid $pid"
else
  echo "!! desktop-lyrics not running — check ~/Library/Logs/desktop-lyrics.log" >&2
  exit 1
fi

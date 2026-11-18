#!/bin/bash
# 发版包里 Mach-O 的两道闸。lyrimuse/package.sh 打包前对每个 .app 调一次,也能单跑:
#
#     scripts/check-release-binaries.sh <Lyrimuse.app>
#     scripts/check-release-binaries.sh --weak-imports <可执行文件>   # 只查第 1 道,提交校验在 swift build 之后对主程序跑
#
# 1. 主程序弱导入的系统符号(dyld_info -fixups 里标 [weak-import] 的)除了 Swift 符号和 Swift 运行时 / libSystem 自己
#    管的那几个,只许出现白名单里的。弱导入的常量在旧系统上是空地址,`#available` 外面直接读它就是启动即崩;
#    新出现一个就得先确认每个读它的地方都在版本判断里面,再加进白名单。
# 2. 自己编的 Mach-O(主程序、引擎、两个命令行工具、nowplaying-clients 的 dylib)和随包 media-control 的两个 Mach-O
#    写的最低系统版本(minos)不高于 Info.plist 的 LSMinimumSystemVersion。dyld 不因 minos 高于运行系统拒载,但编译器
#    按 minos 把新系统才有的符号写成强引用,旧系统上找不到符号就加载失败;App 不报错,只是那一项功能没了。
#    media-control 的 minos 跟着 Homebrew bottle 的系统代号走:lyrimuse/scripts/fetch-media-control.sh 钉的 arm64_sonoma /
#    sonoma 是 14.0,本机 brew 按本机系统挑 bottle(macOS 26 起是 arm64_tahoe,minos 26.0),所以打包不用本机 brew 那份
#    (见 15 章决策 111)。
#
# 不过就打印原因、退出码 1。
set -euo pipefail

weak_only=0
if [ "${1:-}" = "--weak-imports" ]; then
  weak_only=1
  main="${2:?用法: check-release-binaries.sh --weak-imports <可执行文件>}"
else
  app="${1:?用法: check-release-binaries.sh <Lyrimuse.app>}"
  main="$app/Contents/MacOS/lyrimuse"
fi
allowed_weak=(
  "QuartzCore/_CADynamicRangeHigh"
  "AppKit/_OBJC_CLASS_\$_NSGlassEffectView"
  "AppKit/_OBJC_METACLASS_\$_NSGlassEffectView"
  # 只在 x86_64 切片里、不是自家代码引用的;macOS 10.14.4 起就有,14.0 上不会是空地址。
  "libobjc/_objc_setHook_getClass"
  # ProcessAudioTap(灵动岛音浪跟随音乐):类型标了 @available(macOS 14.2, *),调用处都在 #available 里。
  "CoreAudio/_AudioHardwareCreateProcessTap"
  "CoreAudio/_AudioHardwareDestroyProcessTap"
)
own_binaries=(
  "Contents/MacOS/lyrimuse"
  "Contents/Resources/lyrimuse-engine"
  "Contents/Resources/lyrics-translate"
  "Contents/Resources/lyrics-romanize"
  "Contents/Resources/nowplaying-clients/libnowplaying-clients.dylib"
)
bundled_binaries=(
  "Contents/Resources/media-control/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
  "Contents/Resources/media-control/lib/media-control/MediaRemoteAdapterTestClient"
)
failed=0

# lipo / dyld_info 失败时算不过:写在 for 的列表或进程替换里,失败会被吞掉、一个架构都不查就报通过。
archs=""
if ! archs="$(lipo -archs "$main")" || [ -z "$archs" ]; then
  echo "!! 读不出 $main 的架构(lipo -archs 失败)" >&2
  failed=1
  archs=""
fi
for arch in $archs; do
  if ! fixups="$(dyld_info -arch "$arch" -fixups "$main")"; then
    echo "!! $arch 主程序读不出 fixups(dyld_info 失败)" >&2
    failed=1
    continue
  fi
  while IFS= read -r symbol; do
    [ -z "$symbol" ] && continue
    case "$symbol" in
      */_\$s*|libswift*/*|libSystem/*) continue ;;
    esac
    ok=0
    for allowed in "${allowed_weak[@]}"; do
      [ "$symbol" = "$allowed" ] && ok=1
    done
    if [ "$ok" = 0 ]; then
      echo "!! $arch 主程序弱导入了不在白名单里的系统符号: $symbol(确认读它的地方都在 #available 里面后加进 $0 的白名单)" >&2
      failed=1
    fi
  done < <(printf '%s\n' "$fixups" | awk '$NF == "[weak-import]" { print $(NF-1) }' | sort -u)
done
if [ "$weak_only" = 1 ]; then
  [ "$failed" = 0 ] && echo "    弱导入校验通过"
  exit "$failed"
fi

min_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
version_key() {
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  printf '%03d%03d%03d' "${1:-0}" "${2:-0}" "${3:-0}"
}
# check_minos <相对路径>
check_minos() {
  local rel="$1" file="$app/$1" minos build minos_list
  if [ ! -f "$file" ]; then
    echo "!! 找不到 $rel" >&2
    failed=1
    return
  fi
  # vtool 读不出、或没有一条 minos 时算不过:放进进程替换里读的话失败会被吞掉,这一项就静默通过了。
  if ! build="$(vtool -show-build "$file" 2>&1)"; then
    echo "!! $rel 读不出构建版本(vtool -show-build 失败):$build" >&2
    failed=1
    return
  fi
  minos_list="$(printf '%s\n' "$build" | awk '$1 == "minos" { print $2 }' | sort -u)"
  if [ -z "$minos_list" ]; then
    echo "!! $rel 没写 minos(没有 LC_BUILD_VERSION)" >&2
    failed=1
    return
  fi
  while IFS= read -r minos; do
    if [ "$(version_key "$minos")" \> "$(version_key "$min_version")" ]; then
      echo "!! $rel 的 minos 是 $minos,高于 LSMinimumSystemVersion $min_version" >&2
      failed=1
    fi
  done <<< "$minos_list"
}
for rel in "${own_binaries[@]}" "${bundled_binaries[@]}"; do
  check_minos "$rel"
done

if [ "$failed" = 0 ]; then
  echo "    弱导入与最低系统版本校验通过"
fi
exit "$failed"

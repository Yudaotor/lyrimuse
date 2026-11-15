#!/bin/bash
# 发版包里 Mach-O 的两道闸。lyrimuse/package.sh 打包前对每个 .app 调一次,也能单跑:
#
#     scripts/check-release-binaries.sh [--bundled-minos-warn-only] <Lyrimuse.app>
#
# 1. 主程序弱导入的系统符号(dyld_info -fixups 里标 [weak-import] 的)除了 Swift 符号和 Swift 运行时 / libSystem 自己
#    管的那几个,只许出现白名单里的。弱导入的常量在旧系统上是空地址,`#available` 外面直接读它就是启动即崩;
#    新出现一个就得先确认每个读它的地方都在版本判断里面,再加进白名单。
# 2. 自己编的 Mach-O(主程序、引擎、两个命令行工具、nowplaying-clients 的 dylib)和随包 media-control 的两个 Mach-O
#    写的最低系统版本(minos)不高于 Info.plist 的 LSMinimumSystemVersion。dyld 不因 minos 高于运行系统拒载,但编译器
#    按 minos 把新系统才有的符号写成强引用,旧系统上找不到符号就加载失败;App 不报错,只是那一项功能没了。
#    media-control 的 minos 跟着 Homebrew bottle 的系统代号走:CI 钉的 arm64_sonoma / sonoma 是 14.0,本机 brew 按本机
#    系统挑 bottle(macOS 26 起是 arm64_tahoe,minos 26.0)。--bundled-minos-warn-only 时这两个只警告,package.sh 用本机
#    brew 打测试包时传(见 15 章决策 111)。
#
# 不过就打印原因、退出码 1。
set -euo pipefail

bundled_warn_only=0
if [ "${1:-}" = "--bundled-minos-warn-only" ]; then
  bundled_warn_only=1
  shift
fi
app="${1:?用法: check-release-binaries.sh [--bundled-minos-warn-only] <Lyrimuse.app>}"
main="$app/Contents/MacOS/lyrimuse"
allowed_weak=(
  "QuartzCore/_CADynamicRangeHigh"
  "AppKit/_OBJC_CLASS_\$_NSGlassEffectView"
  "AppKit/_OBJC_METACLASS_\$_NSGlassEffectView"
  # 只在 x86_64 切片里、不是自家代码引用的;macOS 10.14.4 起就有,14.0 上不会是空地址。
  "libobjc/_objc_setHook_getClass"
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

for arch in $(lipo -archs "$main"); do
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
  done < <(dyld_info -arch "$arch" -fixups "$main" | awk '$NF == "[weak-import]" { print $(NF-1) }' | sort -u)
done

min_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
version_key() {
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  printf '%03d%03d%03d' "${1:-0}" "${2:-0}" "${3:-0}"
}
# check_minos <相对路径> <只警告 0|1>
check_minos() {
  local rel="$1" warn_only="$2" file="$app/$1" minos
  if [ ! -f "$file" ]; then
    echo "!! 找不到 $rel" >&2
    failed=1
    return
  fi
  while IFS= read -r minos; do
    if [ "$(version_key "$minos")" \> "$(version_key "$min_version")" ]; then
      if [ "$warn_only" = 1 ]; then
        echo "    ⚠ $rel 的 minos 是 $minos,高于 LSMinimumSystemVersion $min_version:本机 brew 的 bottle,这个包在旧系统上 QQ 音乐那一路可能用不了(发版用 CI 钉的 bottle)" >&2
      else
        echo "!! $rel 的 minos 是 $minos,高于 LSMinimumSystemVersion $min_version" >&2
        failed=1
      fi
    fi
  done < <(vtool -show-build "$file" | awk '$1 == "minos" { print $2 }' | sort -u)
}
for rel in "${own_binaries[@]}"; do
  check_minos "$rel" 0
done
for rel in "${bundled_binaries[@]}"; do
  check_minos "$rel" "$bundled_warn_only"
done

if [ "$failed" = 0 ]; then
  echo "    弱导入与最低系统版本校验通过"
fi
exit "$failed"

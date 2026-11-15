#!/bin/bash
# 发版包里 Mach-O 的两道闸。lyrimuse/package.sh 打包前对每个 .app 调一次,也能单跑:
#
#     scripts/check-release-binaries.sh <Lyrimuse.app>
#
# 1. 主程序弱导入的系统符号(dyld_info -fixups 里标 [weak-import] 的)除了 Swift 符号和 Swift 运行时 / libSystem 自己
#    管的那几个,只许出现白名单里的。弱导入的常量在旧系统上是空地址,`#available` 外面直接读它就是启动即崩;
#    新出现一个就得先确认每个读它的地方都在版本判断里面,再加进白名单。
# 2. 自己编的 Mach-O(主程序、引擎、两个命令行工具、nowplaying-clients 的 dylib)写的最低系统版本(minos)不高于
#    Info.plist 的 LSMinimumSystemVersion。高了的那个在旧系统上加载不起来,而且不报错,只是那一项功能没了。
#
# 不过就打印原因、退出码 1。
set -euo pipefail

app="${1:?用法: check-release-binaries.sh <Lyrimuse.app>}"
main="$app/Contents/MacOS/lyrimuse"
allowed_weak=(
  "QuartzCore/_CADynamicRangeHigh"
  "AppKit/_OBJC_CLASS_\$_NSGlassEffectView"
  "AppKit/_OBJC_METACLASS_\$_NSGlassEffectView"
)
own_binaries=(
  "Contents/MacOS/lyrimuse"
  "Contents/Resources/lyrimuse-engine"
  "Contents/Resources/lyrics-translate"
  "Contents/Resources/lyrics-romanize"
  "Contents/Resources/nowplaying-clients/libnowplaying-clients.dylib"
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
for rel in "${own_binaries[@]}"; do
  file="$app/$rel"
  if [ ! -f "$file" ]; then
    echo "!! 找不到 $rel" >&2
    failed=1
    continue
  fi
  while IFS= read -r minos; do
    if [ "$(version_key "$minos")" \> "$(version_key "$min_version")" ]; then
      echo "!! $rel 的 minos 是 $minos,高于 LSMinimumSystemVersion $min_version" >&2
      failed=1
    fi
  done < <(vtool -show-build "$file" | awk '$1 == "minos" { print $2 }' | sort -u)
done

if [ "$failed" = 0 ]; then
  echo "    弱导入与最低系统版本校验通过"
fi
exit "$failed"

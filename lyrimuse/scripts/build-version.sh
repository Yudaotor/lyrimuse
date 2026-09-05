#!/bin/bash
# 展示版本 → CFBundleVersion 构建号(四段纯数字)。**唯一**定义处:build.sh 写 Info.plist、release.yml 生成
# appcast、selftest(update-channel 组)交叉校验 Core 的 ReleaseVersion 都调它,别在别处再写一份映射。
#
#   X.Y.Z            → X.Y.Z.1000     正式版
#   X.Y.Z-alpha.N    → X.Y.Z.N        (1 ≤ N ≤ 99)
#   X.Y.Z-beta.N     → X.Y.Z.(100+N)  (1 ≤ N ≤ 399)
#   X.Y.Z-rc.N       → X.Y.Z.(500+N)  (1 ≤ N ≤ 499)
#   其它形态          → 退出码 1,什么都不打印(前导 v 可有可无;数字不许带前导零)
#
# 为什么要有第四段(2026-09-05):Sparkle 比较版本用的是 sparkle:version / CFBundleVersion,而它的
# SUStandardVersionComparator 实测把 "-" 之后的全部忽略 —— "1.6.0-beta.1" 与 "1.6.0"、"beta.2" 与
# "beta.1" 都判相等。预发布若直接拿 tag 当构建号,beta 用户永远收不到 beta.2、也收不到同号正式版。
# 所以展示版本(CFBundleShortVersionString)保留 tag 原文,构建号另算:正式版 1000 压在所有预发布之上,
# alpha < beta < rc 三档分区互不重叠。老用户机上的 CFBundleVersion 是三段 "1.5.0",Sparkle 比到第二段
# 就分出大小,四段新号照样大于它。
set -euo pipefail
v="${1:-}"
v="${v#v}"
num='(0|[1-9][0-9]*)'
if [[ "$v" =~ ^$num\.$num\.$num$ ]]; then
  echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.1000"
elif [[ "$v" =~ ^$num\.$num\.$num-(alpha|beta|rc)\.([1-9][0-9]{0,2})$ ]]; then
  n="${BASH_REMATCH[5]}"
  case "${BASH_REMATCH[4]}" in
    alpha) (( n <= 99 )) || exit 1; b=$n ;;
    beta)  (( n <= 399 )) || exit 1; b=$((100 + n)) ;;
    rc)    (( n <= 499 )) || exit 1; b=$((500 + n)) ;;
  esac
  echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.$b"
else
  exit 1
fi

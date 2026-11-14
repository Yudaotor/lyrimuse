#!/bin/bash
# 打印正式版二进制 LC_BUILD_VERSION 里的 sdk 版本,供 `build.sh --ci-sdk` 把本机装机改写成同一个值。
# 输出一行「<sdk> <来源>」,来源是 release:<tag>、cache:<tag> 或 arg。
#
#   ci-sdk-version.sh           读最新正式 Release 主包里 Contents/MacOS/lyrimuse 的 sdk 字段
#   ci-sdk-version.sh 26.5      原样采用给定版本(只校验形态)
#
# 正式版的 sdk 字段由 CI 机器的 `xcrun --show-sdk-version` 写入(build.sh 的 stamp_sdk_version),
# release.yml 不钉 Xcode 版本、跟 runner 镜像走,所以只能从发出去的包里读,不能从 workflow 推。
# 结果按 tag 缓存在 ~/Library/Caches/lyrimuse-ci-sdk/<tag>,同一个 tag 只下载一次主包(约 30 MB)。
# 查不到最新 tag(没网、gh 没登录)时退回最近一份缓存并在 stderr 说明;连缓存都没有就退出码 1。
set -euo pipefail

ver_re='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
if [ "$#" -gt 0 ]; then
  if [[ "$1" =~ $ver_re ]]; then
    echo "$1 arg"
    exit 0
  fi
  echo "!! sdk 版本形态不对:$1(要 26.5 这样的数字)" >&2
  exit 1
fi

cache_dir="$HOME/Library/Caches/lyrimuse-ci-sdk"
mkdir -p "$cache_dir"

from_cache() {
  local newest
  newest="$(ls -t "$cache_dir" 2>/dev/null | head -1 || true)"
  if [ -z "$newest" ]; then
    echo "!! 读不到正式版的 sdk 版本,也没有缓存;用 --ci-sdk=<版本> 直接指定" >&2
    exit 1
  fi
  echo "!! $1,改用缓存里 $newest 的读数" >&2
  echo "$(cat "$cache_dir/$newest") cache:$newest"
  exit 0
}

tag="$(gh release view --json tagName -q .tagName 2>/dev/null || true)"
[ -n "$tag" ] || from_cache "查不到最新 Release(gh release view 失败)"

if [ -s "$cache_dir/$tag" ]; then
  echo "$(cat "$cache_dir/$tag") release:$tag"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
asset="Lyrimuse-$tag-macos.zip"
echo "==> 下载 $asset 读 sdk 字段" >&2
gh release download "$tag" -p "$asset" -D "$work" >/dev/null 2>&1 || from_cache "下载 $asset 失败"
unzip -p "$work/$asset" "Lyrimuse.app/Contents/MacOS/lyrimuse" > "$work/lyrimuse" || from_cache "$asset 里没有 Contents/MacOS/lyrimuse"
sdk="$(vtool -show-build "$work/lyrimuse" | awk '/^ *sdk /{print $2; exit}')"
[[ "$sdk" =~ $ver_re ]] || from_cache "$asset 的 sdk 字段读不出(得到 '${sdk}')"
echo "$sdk" > "$cache_dir/$tag.$$"
mv "$cache_dir/$tag.$$" "$cache_dir/$tag"
echo "$sdk release:$tag"

#!/bin/bash
# 取钉住版本的 media-control Homebrew bottle。release.yml、package.sh、build.sh(-intel 变体的 x86_64 半边)都走这一份,
# 版本和 sha256 只钉在这里:
#
#     lyrimuse/scripts/fetch-media-control.sh <arm64_sonoma|sonoma> <解包目录>   stdout 只打一行:解出来的前缀
#     lyrimuse/scripts/fetch-media-control.sh --version                           打印钉住的版本
#
# 按 homebrew-core formula 里的 sha256 从 ghcr 直取 blob,不经 brew:brew 按所在机器的系统挑 bottle(macOS 26 起是 arm64_tahoe,
# 两个 Mach-O 的 minos 26.0),runner 的 brew 索引也会走到新版本。arm64_sonoma / sonoma 的 minos 是 14.0,等于
# LSMinimumSystemVersion,scripts/check-release-binaries.sh 查(15 章决策 111)。版本钉在 0.7.6:0.7.7 起 homebrew-core
# 不再产 Intel bottle,改钉版前先读 build.sh 合 x86_64 切片那段注释。sha256 抄自 homebrew-core 4d7e1515ad 的 formula。
#
# 下载的 bottle 按 sha256 命名缓存在 LYRIMUSE_MEDIA_CONTROL_CACHE(默认 ~/Library/Caches/lyrimuse-media-control),每次用前
# 重新校验:缓存那份不符就删掉重下,下载的不符拒绝、退出码 1。
set -euo pipefail

PIN_VER="0.7.6"
usage="用法: fetch-media-control.sh <arm64_sonoma|sonoma> <解包目录> | --version"

tag="${1:?$usage}"
case "$tag" in
  --version) echo "$PIN_VER"; exit 0 ;;
  arm64_sonoma) sha="179a21d0233706e75adcb70048386b3e471ad364e192e8ba0da80121a09d4ce4" ;;
  sonoma) sha="52a07ebec136e88574c620dfaa6cf2121d37aade09967bf4d6bab0d316ee6aac" ;;
  *) echo "!! 不认识的 bottle tag「${tag}」。$usage" >&2; exit 2 ;;
esac
dest="${2:?$usage}"

cache="${LYRIMUSE_MEDIA_CONTROL_CACHE:-$HOME/Library/Caches/lyrimuse-media-control}"
mkdir -p "$cache"
tgz="$cache/media-control-$PIN_VER-$tag-$sha.tar.gz"
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if [ -f "$tgz" ]; then
  if [ "$(sha_of "$tgz")" = "$sha" ]; then
    echo "==> media-control $PIN_VER $tag: 用缓存 $tgz" >&2
  else
    echo "!! 缓存的 media-control $tag bottle 校验不过,删掉重下: $tgz" >&2
    rm -f "$tgz"
  fi
fi
if [ ! -f "$tgz" ]; then
  tmp="$(mktemp "$cache/.download.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  echo "==> media-control $PIN_VER $tag: 从 ghcr 下载 sha256:$sha" >&2
  curl -fsSL -H "Authorization: Bearer QQ==" \
    "https://ghcr.io/v2/homebrew/core/media-control/blobs/sha256:$sha" -o "$tmp"
  got="$(sha_of "$tmp")"
  if [ "$got" != "$sha" ]; then
    echo "!! media-control $tag bottle 校验不过:拿到 $got,期望 $sha,拒绝使用" >&2
    exit 1
  fi
  mv -f "$tmp" "$tgz"
fi

mkdir -p "$dest"
rm -rf "$dest/media-control"
tar -xzf "$tgz" -C "$dest"
prefix="$dest/media-control/$PIN_VER"
if [ ! -x "$prefix/bin/media-control" ]; then
  echo "!! 解出来的 bottle 里没有 $prefix/bin/media-control(bottle 结构变了?)" >&2
  exit 1
fi
echo "$prefix"

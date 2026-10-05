#!/bin/sh
# 直接测试 native 归一化和同 client 查询,不操作真实播放器、不依赖私有接口权限。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lyrimuse-nowplaying-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
clang -fobjc-arc -O2 -framework Foundation \
    "$root/lyrimuse/native/nowplaying-clients/nowplaying-clients-test.m" \
    -o "$tmp/nowplaying-clients-test"
"$tmp/nowplaying-clients-test"

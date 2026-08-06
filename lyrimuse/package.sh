#!/usr/bin/env bash
# 把**已经构建好**的 /Applications/Lyrimuse.app 打成发布资产,输出到 lyrimuse/dist/:
#
#   Lyrimuse-v<版本>-macos.zip         Sparkle 自动更新的载荷,同时也是 Homebrew cask 的下载源
#   Lyrimuse-v<版本>-macos.zip.sha256  给手动核对下载的人用
#   Lyrimuse-v<版本>-macos.dmg         只给手动下载的人:双击挂载、把图标拖进 Applications
#
# 用法:
#   ./build.sh --no-restart && ./package.sh
#
# 为什么 zip 和 dmg 都出、而不是换成只有 dmg:这个 zip 有两个消费者不能动 ——
# appcast.xml 里的 <enclosure> 直接指向它(Sparkle 下载并解开这个 zip 完成自我升级),
# Homebrew cask 也是从同一个 zip 安装。dmg 纯粹是给"去 Releases 页面手动下载"的人的,
# 观感更像一个正经 macOS 应用的分发方式。两份必须来自**同一次构建**,所以由这一个脚本
# 一起产出,而不是各打各的 —— 否则很容易出现 zip 和 dmg 里装的其实不是同一份二进制。
#
# 为什么单独一个脚本、不塞进 build.sh:build.sh 的职责是"构建并装到 /Applications 上跑",
# 本地每次迭代都会跑;打 zip/dmg 只在发布时需要,压缩和 hdiutil 都不便宜,没必要让日常
# 构建背着。同时也把"发布包到底是怎么打出来的"这件事写进仓库 —— 在此之前它只存在于
# 手工操作里,没有任何脚本记录。
#
# 这个脚本**不做**签名/公证/上传:Sparkle 的 EdDSA 私钥和 GitHub 凭据都不该被一个打包
# 脚本碰。剩下的手工步骤在最后会打印出来。
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse/
APP_DIR="/Applications/Lyrimuse.app"
DIST="dist"

if [ ! -d "$APP_DIR" ]; then
  echo "!! 找不到 $APP_DIR —— 先跑 ./build.sh" >&2
  exit 1
fi

# 版本号从**构建产物自己的 Info.plist** 里读,不从环境变量或参数拿 —— 要打包的就是这个
# 包,它自称什么版本就是什么版本。顺带能抓住"忘了设 LYRIMUSE_VERSION"这种情况:那样
# build.sh 会落下占位的 1.0.0,这里就会照实打出 v1.0.0,一眼看得出不对。
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist")"
if [ -z "$VERSION" ]; then
  echo "!! 读不出 CFBundleShortVersionString" >&2
  exit 1
fi
BASE="Lyrimuse-v$VERSION-macos"
echo "==> packaging Lyrimuse v$VERSION"

# 发布闸门:这里对"不是 universal"是**硬失败**,不像 build.sh 那样只打警告。v1.0.0~v1.2.0
# 三个版本都是在没人察觉的情况下发成 arm64-only 的,而发布是不可撤回的动作 —— 唯一可靠
# 的拦法就是"打包这一步过不去"。本地想要一份瘦包自己 ditto,别走这个脚本。
echo "==> verifying universal"
THIN=""
while IFS= read -r f; do
  archs="$(lipo -archs "$f" 2>/dev/null || true)"
  [ -z "$archs" ] && continue # 脚本/资源,没有架构这回事
  case "$archs" in
    *arm64*) case "$archs" in *x86_64*) ;; *) THIN="$THIN ${f#$APP_DIR/}" ;; esac ;;
    *) THIN="$THIN ${f#$APP_DIR/}" ;;
  esac
done < <(find "$APP_DIR" -type f -perm -u+x)
if [ -n "$THIN" ]; then
  echo "!! 以下二进制不是 universal,拒绝打包:" >&2
  for f in $THIN; do echo "     $f" >&2; done
  echo "!! 用 ./build.sh(默认 universal)重新构建,不要带 --host-only" >&2
  exit 1
fi
echo "    所有二进制都是 arm64 + x86_64"

# 签名也在这里再验一遍 —— build.sh 结尾验过,但那之后包可能被别的操作动过(比如手工
# 拷进去点什么),而签名一坏,用户那边表现成"打开就闪退",发出去才发现代价太大。
echo "==> verifying signature"
codesign -v --deep --strict "$APP_DIR"
echo "    codesign --deep --strict 通过"

rm -rf "$DIST"
mkdir -p "$DIST"

# zip:用 ditto 而不是 zip(1) —— Sparkle 的文档和 Sparkle.framework 自己的打包脚本都
# 用 ditto,因为它保留资源分叉、扩展属性和符号链接;zip(1) 会把 framework 里的符号链接
# 拆成实体拷贝,进而破坏代码签名(build.sh 里嵌 Sparkle 时踩的是同一个坑)。
# --keepParent 让解压出来是 Lyrimuse.app 而不是散落的 Contents/。
echo "==> zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST/$BASE.zip"
# sha256 文件里只放基名,不放绝对路径 —— 跟已发布的那几个资产格式保持一致
# (`shasum -a 256 <basename>` 的原样输出),这样用户下载后在同一个目录里
# `shasum -c` 能直接过。
(cd "$DIST" && shasum -a 256 "$BASE.zip" > "$BASE.zip.sha256")

# dmg:只用 hdiutil,不驱动 Finder。
#
# 挂载后那个"带背景图、图标摆好位置"的窗口需要用 AppleScript 让 Finder 去排版
# (mount 一个可写镜像 → tell application "Finder" 设窗口 bounds 和图标坐标 → 转成只读
# 压缩镜像),那是有副作用的 GUI 自动化,故意不做。现在出的是干净可用的形态:挂载后一个
# 普通 Finder 窗口,里面 Lyrimuse.app 和一个指向 /Applications 的替身,拖过去即可。
#
# 用 ditto 而不是 cp -R 往暂存目录拷,理由跟上面 zip 一样(符号链接/签名)。
# -format UDZO = 只读 + zlib 压缩,是分发用 dmg 的常规格式;-fs HFS+ 而不是 APFS,
# HFS+ 的只读压缩镜像兼容面最宽,对一份只用来拖一次的分发镜像没有理由挑 APFS。
#
# dmg 本身不签名:这个项目通篇是 ad-hoc 签名、没有公证(见 README),给镜像盖一个 ad-hoc
# 签名不会改变用户那边的任何行为 —— 下载下来照样带 com.apple.quarantine,拖进
# /Applications 的 app 会继承这个标记,还是需要 README 里那一次 xattr。与其造成"这个
# dmg 是签过的"的错觉,不如保持跟 zip 一致的诚实状态。
echo "==> dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_DIR" "$STAGE/Lyrimuse.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "Lyrimuse" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov -quiet \
  "$DIST/$BASE.dmg"

echo
echo "==> dist/"
for f in "$DIST/$BASE.zip" "$DIST/$BASE.zip.sha256" "$DIST/$BASE.dmg"; do
  # 用 stat 拿真实字节数再换算,不用 du —— du 报的是块分配量,92 字节的 .sha256 会被
  # 显示成 "4.0K",看着像出了什么问题。
  printf "    %-34s %s\n" "$(basename "$f")" \
    "$(/usr/bin/python3 -c "import sys;n=int(sys.argv[1]);print(f'{n/1048576:.2f} MB' if n>=1048576 else (f'{n/1024:.1f} KB' if n>=1024 else f'{n} B'))" "$(stat -f %z "$f")")"
done
echo
echo "==> 剩下的手工步骤(这个脚本故意不做):"
echo "    1) 用 Sparkle 的 sign_update 给 $BASE.zip 签 EdDSA,生成/更新 appcast.xml"
echo "       (私钥在钥匙串里,不经过这个脚本)"
echo "    2) gh release create v$VERSION --title \"Lyrimuse v$VERSION\" \\"
echo "         dist/$BASE.zip dist/$BASE.zip.sha256 dist/$BASE.dmg appcast.xml"
echo "    3) 更新 Homebrew cask(Yudaotor/homebrew-lyrimuse)的 version 和 sha256:"
echo "       sha256 = $(awk '{print $1}' "$DIST/$BASE.zip.sha256")"
echo "       cask 继续指向 zip,不要改成 dmg —— Sparkle 和 cask 共用那一份"

#!/usr/bin/env bash
# 打发布资产。自己调 build.sh 构建两份 .app,输出到 lyrimuse/dist/:
#
#   Lyrimuse-v<版本>-macos.zip           arm64-only —— **主包**
#   Lyrimuse-v<版本>-macos.zip.sha256
#   Lyrimuse-v<版本>-macos.dmg           同上,给手动下载的人
#   Lyrimuse-v<版本>-macos-intel.zip     universal(arm64 + x86_64)—— 只给 Intel 用户
#   Lyrimuse-v<版本>-macos-intel.zip.sha256
#   Lyrimuse-v<版本>-macos-intel.dmg
#
# 用法:
#   LYRIMUSE_VERSION=1.2.1 ./package.sh
#
# 为什么分成两份而不是只发一个 universal:包里一旦含 x86_64 代码,macOS 27 会弹"需要更新
# App —— 此版本包含的一个组件无法在下个主要版本 macOS 28 中打开"(macOS 28 移除 Rosetta),
# 这条告警会打在**多数用户**(Apple Silicon)脸上,而 App 本身没有任何问题。主包做成
# arm64-only 就彻底没有这个触发条件,顺带下载体积小一半;Intel 用户走单独那份 -intel。
# 详细来龙去脉见 build.sh 顶部注释。
#
# 为什么 zip 和 dmg 都出:zip 有两个消费者不能动 —— appcast.xml 的 <enclosure> 指向它
# (Sparkle 下载并解开这个 zip 完成自我升级),Homebrew cask 也从同一个 zip 安装。dmg 纯粹
# 是给"去 Releases 页面手动下载"的人的,观感更像正经的 macOS 分发方式。
#
# ⚠️ appcast 里**主包那条 item 必须带这个子元素**:
#
#     <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
#
# Sparkle 在 Intel 客户端上会据此判定该条不适用、直接跳过(见 Sparkle 的
# SPUAppcastItemStateResolver.isArm64HardwareRequirementOK),于是 Intel 用户只会看到"已是
# 最新",而不会被推一个 arm64-only、装上就打不开的包。漏了它,Intel 用户会被自动更新推坏
# —— 这是这套双资产方案里唯一一处"漏了就出事"的地方。
#
# 它是 <item> 的**子元素**,不是 <enclosure> 上的属性。这行注释 2026-08-07 之前写的就是
# 属性写法(sparkle:hardwareRequirements="arm64"),错的:Sparkle 用
# SUAppcastElementHardwareRequirements = "sparkle:hardwareRequirements" 从 item 的元素字典里
# 取值,它自己的测试样例(Tests/Resources/testappcast_arm64HardwareRequirement.xml)也是写成
# 元素。写成属性 XML 解析不报错、但匹配不到任何东西 —— 于是每个 Intel 客户端照样会被推
# 这条更新,正好是它要防的那件事。
#
# 为什么不塞进 build.sh:build.sh 每次本地迭代都跑、职责是装了就重启;这里要构建两份、压缩、
# 跑 hdiutil,只在发布时需要。同时也把"发布包到底是怎么打出来的"写进仓库 —— 在此之前它只
# 存在于手工操作里,没有任何脚本记录。
#
# 这个脚本**不做**签名/公证/上传:Sparkle 的 EdDSA 私钥和 GitHub 凭据都不该被打包脚本碰。
# 剩下的手工步骤在最后会打印出来。
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse/
DIST="dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 每个变体:名字后缀 | build.sh 参数 | 期望架构集
# 主包放前面 —— 它是绝大多数人要下的那个,日志里先出现更顺眼。
VARIANTS=(
  "|--dest|arm64"
  "-intel|--universal --dest|arm64 x86_64"
)

echo "==> building variants"
VERSION=""
for v in "${VARIANTS[@]}"; do
  suffix="${v%%|*}"; rest="${v#*|}"; flags="${rest%%|*}"; want="${rest##*|}"
  label="${suffix:-(主包)}"
  echo "--> $label [$want]"
  app="$STAGE/${suffix:-primary}/Lyrimuse.app"
  # shellcheck disable=SC2086 # flags 需要按空格拆成多个参数
  ./build.sh $flags "$app" > "$STAGE/build${suffix}.log" 2>&1 || {
    echo "!! build.sh 失败,日志尾部:" >&2; tail -20 "$STAGE/build${suffix}.log" >&2; exit 1
  }
  # 版本号从**构建产物自己的 Info.plist** 里读,不从参数拿 —— 打的就是这个包,它自称什么
  # 版本就是什么版本。顺带能抓住"忘了设 LYRIMUSE_VERSION":那样会照实打出 v1.0.0,一眼看得
  # 出不对,而不是发一个标错版本的包。
  ver="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
  [ -n "$ver" ] || { echo "!! 读不出 CFBundleShortVersionString" >&2; exit 1; }
  if [ -z "$VERSION" ]; then VERSION="$ver"; elif [ "$VERSION" != "$ver" ]; then
    echo "!! 两个变体版本号不一致($VERSION vs $ver)" >&2; exit 1
  fi

  # 发布闸门:架构不符是**硬失败**,不像 build.sh 那样只打警告。v1.0.0~v1.2.0 三个版本都是
  # 在没人察觉的情况下发成 arm64-only 的,而发布不可撤回 —— 唯一可靠的拦法就是"打包这步
  # 过不去"。两个方向都查:主包多带一份 x86_64 就会触发那条 macOS 告警,Intel 包少一半就
  # 等于没做。用 find -type f(不加 -perm)以免漏掉没有执行位的 Mach-O。
  bad=""
  while IFS= read -r f; do
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    [ -z "$archs" ] && continue
    for a in $want; do
      case " $archs " in *" $a "*) ;; *) bad="$bad ${f#$app/}(缺$a)" ;; esac
    done
    for a in $archs; do
      case " $want " in *" $a "*) ;; *) bad="$bad ${f#$app/}(多余$a)" ;; esac
    done
  done < <(find "$app" -type f)
  if [ -n "$bad" ]; then
    echo "!! $label 架构与期望[$want]不符,拒绝打包:" >&2
    for f in $bad; do echo "     $f" >&2; done
    exit 1
  fi
  # 签名也验一遍 —— 签名一坏,用户那边表现成"打开就闪退",发出去才发现代价太大。
  codesign -v --deep --strict "$app"
  echo "    架构与签名校验通过"
done

rm -rf "$DIST"
mkdir -p "$DIST"

human_size() {
  /usr/bin/python3 -c "import sys;n=int(sys.argv[1]);print(f'{n/1048576:.2f} MB' if n>=1048576 else (f'{n/1024:.1f} KB' if n>=1024 else f'{n} B'))" "$(stat -f %z "$1")"
}

echo "==> packaging"
for v in "${VARIANTS[@]}"; do
  suffix="${v%%|*}"
  app="$STAGE/${suffix:-primary}/Lyrimuse.app"
  base="Lyrimuse-v$VERSION-macos$suffix"

  # zip 用 ditto 而不是 zip(1) —— Sparkle 的文档和它自己的打包脚本都用 ditto,因为它保留
  # 资源分叉、扩展属性和符号链接;zip(1) 会把 framework 里的符号链接拆成实体拷贝,进而破坏
  # 代码签名(build.sh 里嵌 Sparkle 时踩的是同一个坑)。--keepParent 让解压出来是
  # Lyrimuse.app 而不是散落的 Contents/。
  ditto -c -k --sequesterRsrc --keepParent "$app" "$DIST/$base.zip"
  # sha256 文件里只放基名不放绝对路径,跟已发布的那几个资产格式保持一致
  # (`shasum -a 256 <basename>` 的原样输出),这样用户在同一目录里 `shasum -c` 能直接过。
  (cd "$DIST" && shasum -a 256 "$base.zip" > "$base.zip.sha256")

  # dmg:只用 hdiutil,不驱动 Finder。挂载后那个"带背景图、图标摆好位置"的窗口需要挂一个
  # 可写镜像再用 AppleScript 让 Finder 设窗口 bounds 和图标坐标,那是有副作用的 GUI 自动化,
  # 故意不做。现在出的是干净可用的形态:一个普通 Finder 窗口,里面 Lyrimuse.app 和一个指向
  # /Applications 的替身,拖过去即可。
  #
  # -format UDZO = 只读 + zlib 压缩,分发用 dmg 的常规格式;-fs HFS+ 而不是 APFS,HFS+ 的
  # 只读压缩镜像兼容面最宽,对一份只用来拖一次的镜像没理由挑 APFS。
  #
  # dmg 本身不签名:这个项目通篇 ad-hoc 签名、没有公证(见 README),给镜像盖一个 ad-hoc 签名
  # 不会改变用户那边任何行为 —— 下载下来照样带 com.apple.quarantine,拖进 /Applications 的
  # app 会继承这个标记,还是要做 README 里那一次 xattr。与其造成"这个 dmg 是签过的"的错觉,
  # 不如保持跟 zip 一致的诚实状态。
  dmgstage="$STAGE/dmg$suffix"
  rm -rf "$dmgstage"; mkdir -p "$dmgstage"
  ditto "$app" "$dmgstage/Lyrimuse.app"
  ln -s /Applications "$dmgstage/Applications"
  # 卷名区分开:两份镜像同名时,同时挂载会被系统加后缀成 "Lyrimuse 1",看不出哪份是哪份。
  hdiutil create -volname "Lyrimuse${suffix:+ (Intel)}" -srcfolder "$dmgstage" \
    -fs HFS+ -format UDZO -ov -quiet "$DIST/$base.dmg"

  printf "    %-40s %s\n" "$base.zip" "$(human_size "$DIST/$base.zip")"
  printf "    %-40s %s\n" "$base.zip.sha256" "$(human_size "$DIST/$base.zip.sha256")"
  printf "    %-40s %s\n" "$base.dmg" "$(human_size "$DIST/$base.dmg")"
done

PRIMARY="Lyrimuse-v$VERSION-macos"
INTEL="Lyrimuse-v$VERSION-macos-intel"
echo
echo "==> 剩下的手工步骤(这个脚本故意不做):"
echo "    1) 给**主包** zip 签 EdDSA、生成 appcast.xml,那条 item 必须带:"
echo "         <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>   (item 的子元素,不是 enclosure 的属性)"
echo "       (没有它,Intel 用户会被自动更新推一个 arm64-only 的包,装上打不开)"
echo "       enclosure 指向 $PRIMARY.zip,不要指向 -intel 那份"
echo "    2) gh release create v$VERSION --title \"Lyrimuse v$VERSION\" \\"
echo "         dist/$PRIMARY.zip dist/$PRIMARY.zip.sha256 dist/$PRIMARY.dmg \\"
echo "         dist/$INTEL.zip dist/$INTEL.zip.sha256 dist/$INTEL.dmg appcast.xml"
echo "       release notes 里写清楚:普通用户下不带后缀那份,Intel Mac 下 -intel 那份"
echo "    3) 更新 Homebrew cask(Yudaotor/homebrew-lyrimuse):version + sha256,"
echo "       并加 depends_on arch: :arm64(cask 装的是主包,Intel 机器该被拒绝而不是装个跑不了的)"
echo "       主包 sha256 = $(awk '{print $1}' "$DIST/$PRIMARY.zip.sha256")"

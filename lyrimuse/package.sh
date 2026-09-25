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
# appcast(两个 item,主包那条带 <sparkle:hardwareRequirements>arm64</...> 子元素)由 release.yml 生成,
# 形状由 .github/scripts/check_appcast.py 校验,见 docs/releasing.md「流水线的硬约束」。
#
# 不塞进 build.sh:build.sh 每次本地迭代都跑、职责是装了就重启;这里要构建两份、压缩、跑 hdiutil,
# 只在发布时需要。
#
# 这个脚本**不做** EdDSA 签名 / 上传:Sparkle 私钥和 GitHub 凭据都不该被打包脚本碰,那两步在 release.yml。
set -euo pipefail

cd "$(dirname "$0")" # lyrimuse/
ROOT="$PWD"
DIST="dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# DMG 美化用得到的两样东西。PYTHON_BIN 可以从外面覆盖 —— dmgbuild 常见的装法是装进
# 某个虚拟环境,而不是系统 Python。
PYTHON_BIN="${PYTHON_BIN:-python3}"
DMG_BACKGROUND="$STAGE/dmg-background.tiff"

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

  # 发布闸门:架构不符是**硬失败**,不像 build.sh 那样只打警告 —— 发布不可撤回,唯一可靠的拦法
  # 是"打包这步过不去"。两个方向都查:主包多带一份 x86_64 就会触发那条 macOS 告警,Intel 包少一半就
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
  # 发布闸门:主执行文件 LC_BUILD_VERSION 里的 sdk 必须 >= 26。macOS 26 起系统按这个字段
  # 决定给不给 App 上液态玻璃,写小了整个 App 被按改版前的外观渲染,**而且不报任何错** ——
  # `#available(macOS 26.0, *)` 照样为真、`.glassEffect` 照样调用,只是系统不给画。
  #
  # 它跟部署目标是两回事:minos 仍然是 14.0,所以 macOS 14/15 上 #available 为假、自然
  # 退回改版前的外观。这道闸管的是"新系统上该有玻璃",不会把旧系统挡在门外。
  #
  # 为什么需要闸:SwiftPM 的新构建系统往这个字段写的是部署目标而不是真实 SDK 版本
  # (见 build.sh 的 stamp_sdk_version),一次工具链升级就能让它悄悄变回去 —— 而发布不可
  # 撤回,跟上面那条架构闸是同一个道理。
  sdk_field="$(vtool -show-build "$app/Contents/MacOS/lyrimuse" | awk '/^ *sdk /{print $2; exit}')"
  sdk_major="${sdk_field%%.*}"
  case "$sdk_major" in
    ''|*[!0-9]*) echo "!! $label 读不出 sdk 字段(拿到「$sdk_field」),拒绝打包" >&2; exit 1 ;;
  esac
  if [ "$sdk_major" -lt 26 ]; then
    echo "!! $label 的 sdk 字段是 $sdk_field(<26)——这样发出去在 macOS 26+ 上没有液态玻璃,拒绝打包" >&2
    exit 1
  fi
  # 签名也验一遍 —— 签名一坏,用户那边表现成"打开就闪退",发出去才发现代价太大。
  codesign -v --deep --strict "$app"
  # 发布闸门:签名要求必须是「identifier + 证书根」,不能是 cdhash。ad-hoc 签名的要求是一条 cdhash,
  # 用户每次更新后 TCC 里的辅助功能 / 自动化 / 完全磁盘访问授权都对不上、勾亮着却失效;而证书那头
  # 缺了(Secret 过期、导入失败)build.sh 会静默退回 ad-hoc,所以只能在这里拦。
  # LYRIMUSE_REQUIRE_STABLE_SIGNATURE=1 时硬失败(release.yml 打 tag 时设),否则只警告。
  # App 本体和 collector 都查:两者各自持有 TCC 授权。
  for signed in "$app" "$app/Contents/Resources/collector"; do
    req="$(codesign -d -r- "$signed" 2>&1 | awk '/designated =>/{sub(/.*designated => /,""); print; exit}')"
    case "$req" in
      *"certificate root"*) ;;
      *)
        if [ "${LYRIMUSE_REQUIRE_STABLE_SIGNATURE:-}" = 1 ]; then
          echo "!! $label ${signed#"$STAGE"/} 的签名要求不是固定证书(拿到「$req」),拒绝打包" >&2
          exit 1
        fi
        echo "    ⚠ ${signed#"$STAGE"/} 是 ad-hoc 签名:用户更新后系统授权会失效(发布构建会在这里失败)" >&2
        ;;
    esac
  done
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

  # dmg:优先用 dmgbuild 出"带背景图、图标摆好位置"的窗口,拿不到 dmgbuild 就退回
  # 纯 hdiutil。
  #
  # 之前这里写的是"美化窗口需要挂可写镜像再用 AppleScript 让 Finder 设窗口
  # bounds 和图标坐标,那是有副作用的 GUI 自动化,故意不做"。这个前提对 dmgbuild 不成立:
  # 它自己实现了 .DS_Store 的格式、直接写进镜像,全程不启动 Finder。所以"不驱动 Finder"
  # 这条底线保住了,美化也能做。
  #
  # 退回路径保留而不是硬性要求装 dmgbuild:出 DMG 这件事本身不该因为少一个 Python 包
  # 就整个失败,而且两条路径的产物在功能上完全等价(同样的 HFS+/UDZO、同样的 app +
  # Applications 替身),差的只是观感。
  #
  # -format UDZO = 只读 + zlib 压缩,分发用 dmg 的常规格式;-fs HFS+ 而不是 APFS,HFS+ 的
  # 只读压缩镜像兼容面最宽,对一份只用来拖一次的镜像没理由挑 APFS。
  #
  # dmg 本身不签名:这个项目通篇 ad-hoc 签名、没有公证(见 README),给镜像盖一个 ad-hoc 签名
  # 不会改变用户那边任何行为 —— 下载下来照样带 com.apple.quarantine,拖进 /Applications 的
  # app 会继承这个标记,还是要做 README 里那一次 xattr。与其造成"这个 dmg 是签过的"的错觉,
  # 不如保持跟 zip 一致的诚实状态。
  # 卷名区分开:两份镜像同名时,同时挂载会被系统加后缀成 "Lyrimuse 1",看不出哪份是哪份。
  volname="Lyrimuse${suffix:+ (Intel)}"
  dmgstage="$STAGE/dmg$suffix"
  rm -rf "$dmgstage"; mkdir -p "$dmgstage"
  ditto "$app" "$dmgstage/Lyrimuse.app"

  if "$PYTHON_BIN" -c "import dmgbuild" >/dev/null 2>&1; then
    if [ ! -f "$DMG_BACKGROUND" ]; then
      # 背景图现生成(见那个脚本开头:图形用代码描述比塞一张二进制设计稿进仓库更好审阅)。
      swift "$ROOT/scripts/make_dmg_background.swift" "$DMG_BACKGROUND"
    fi
    LYRIMUSE_DMG_APP="$dmgstage/Lyrimuse.app" \
    LYRIMUSE_DMG_VOLNAME="$volname" \
    LYRIMUSE_DMG_BACKGROUND="$DMG_BACKGROUND" \
      "$PYTHON_BIN" -m dmgbuild -s "$ROOT/scripts/dmg_settings.py" \
        "$volname" "$DIST/$base.dmg" >/dev/null
  else
    echo "    (没装 dmgbuild,退回纯 hdiutil:产物功能一样,只是没有背景图和图标摆位)"
    ln -s /Applications "$dmgstage/Applications"
    hdiutil create -volname "$volname" -srcfolder "$dmgstage" \
      -fs HFS+ -format UDZO -ov -quiet "$DIST/$base.dmg"
  fi

  printf "    %-40s %s\n" "$base.zip" "$(human_size "$DIST/$base.zip")"
  printf "    %-40s %s\n" "$base.zip.sha256" "$(human_size "$DIST/$base.zip.sha256")"
  printf "    %-40s %s\n" "$base.dmg" "$(human_size "$DIST/$base.dmg")"
done

echo
echo "==> 资产已就绪。appcast、签名与发布由 release.yml 在打 tag 时完成;Homebrew cask 用 CI 发布的"
echo "    .sha256 资产更新(本地包的哈希跟 CI 的不同)。完整步骤见 docs/releasing.md。"

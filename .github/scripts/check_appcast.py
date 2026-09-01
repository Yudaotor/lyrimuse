#!/usr/bin/env python3
"""校验 release.yml 生成的 appcast.xml 形状对不对。

用法:  python3 .github/scripts/check_appcast.py appcast.xml

# 为什么需要这道闸

appcast 只在**真打 tag** 时才生成得出来,而它错了的表现全是**静默**的:

  - 少一个 item          → 那个架构的用户再也收不到更新,只看到"已是最新"
  - 两个 item 顺序反了   → arm64 用户开始白下 2 倍大的 universal 包(照样装得上、跑得起来,
                            所以永远没人会发现)
  - hardwareRequirements 写成 <enclosure> 的属性而不是 <item> 的子元素
                          → 解析通过、匹配不到任何东西,于是把 arm64 包递给每个 Intel
                            客户端 —— 一个在他们机器上根本起不来的包
  - edSignature 或 length 为空 → Sparkle 拒收,用户端仍然只显示"已是最新"

没有哪一条会让发布流程报错,全靠用户来报"更新没了"。所以在 CI 里当场断言。

# 为什么是独立文件而不是内嵌 heredoc

`run: |` 块里每一行的缩进都不能浅于块本身,而 heredoc 的体又必须顶格(否则 python 收到的
每行都带前导空白、直接 IndentationError)。这两条互相冲突 —— release.yml 里记着 2026-08-16
踩过这个坑。放独立文件同时还能本地直接跑:

    python3 .github/scripts/check_appcast.py 某份appcast.xml

# 判据来自哪里

两个 item 的分流机制见 Sparkle 的 SUAppcastDriver.filterSupportedAppcast:(先按
arm64HardwareRequirementIsOK 剔,再 bestItemFromAppcastItems: 挑)与它自己的单测
Tests/SUAppcastTest.swift testARM64Requirement。"版本相同取先出现的那个"来自
bestItemFromAppcastItems: 的注释 "if two items are equal, we must select the first
matching one" —— 这就是顺序必须 arm64 在前的原因。
"""
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def check(path: str) -> list[str]:
    problems: list[str] = []
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        return [f"读不了/解析不动 {path}: {e}"]

    items = root.findall("./channel/item")
    if len(items) != 2:
        problems.append(f"item 数应为 2(arm64 + intel),实际 {len(items)}")

    for i, item in enumerate(items):
        where = f"item[{i}]"
        hw = [e.text for e in item.findall(f"{{{SPARKLE_NS}}}hardwareRequirements")]
        enc = item.find("enclosure")
        if enc is None:
            problems.append(f"{where} 没有 <enclosure>")
            continue
        url = enc.get("url") or ""
        sig = enc.get(f"{{{SPARKLE_NS}}}edSignature") or ""
        length = enc.get("length") or ""

        # 顺手兜住"写成属性"那个坑:属性形态解析得过,但 Sparkle 读的是子元素。
        if enc.get(f"{{{SPARKLE_NS}}}hardwareRequirements") or enc.get("sparkle:hardwareRequirements"):
            problems.append(
                f"{where} 把 hardwareRequirements 写成了 <enclosure> 的属性 —— "
                "Sparkle 只认 <item> 的子元素,属性形态会静默匹配不到任何东西")
        if not sig:
            problems.append(f"{where} 没有 sparkle:edSignature")
        if not length.isdigit() or int(length) <= 0:
            problems.append(f"{where} length 非法: {length!r}")
        if not url.endswith(".zip"):
            problems.append(f"{where} enclosure url 不是 .zip: {url!r}")

        if i == 0:
            if hw != ["arm64"]:
                problems.append(
                    f"{where} 必须且只能带一个 hardwareRequirements=arm64,实际 {hw!r}")
            if "-intel.zip" in url:
                problems.append(
                    f"{where} 指向了 -intel 包 —— 两个 item 顺序反了。版本号相同时 Sparkle "
                    "取先出现的那个,arm64 用户会开始白下 2 倍大的 universal 包(而且装得上、"
                    "跑得起来,没人会发现)")
        else:
            if hw:
                problems.append(
                    f"{where}(intel)不该带 hardwareRequirements,实际 {hw!r} —— "
                    "带了就等于 Intel 客户端把它也剔掉,两个架构都收不到更新")
            if "-intel.zip" not in url:
                problems.append(f"{where} 应指向 -intel 包,实际 {url!r}")

    # 两个 item 必须是同一个版本(它们是同一次发布的两种架构,不是两次发布)。
    versions = {
        (item.findtext(f"{{{SPARKLE_NS}}}version") or "").strip()
        for item in items
    }
    if len(versions) > 1:
        problems.append(f"两个 item 的 sparkle:version 不一致: {sorted(versions)!r}")
    if "" in versions:
        problems.append("有 item 缺 sparkle:version")

    return problems


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    problems = check(sys.argv[1])
    if problems:
        print("appcast 自检失败:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print("appcast 自检通过:2 个 item,arm64 在前带 hardwareRequirements,intel 在后不带")
    return 0


if __name__ == "__main__":
    sys.exit(main())

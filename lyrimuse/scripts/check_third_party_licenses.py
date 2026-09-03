#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第三方许可声明覆盖检查:随包分发的每个依赖,THIRD_PARTY_LICENSES 里都得提到。

2026-09-03 加。BSD/MIT 的二进制分发条款要求随附版权声明与许可证文本,仓库靠根目录的
THIRD_PARTY_LICENSES 一个文件满足它(build.sh 拷进 Contents/Resources/,设置「关于 → 第三方许可」
打开的就是这份)。漂移的典型形态是"加了第三个 SPM 包 / collector 引入第一个 Go 模块,忘了补声明",
等发出去才被人指出来。这里把三处依赖来源机械对一遍:
  1. lyrimuse/Package.resolved 每个 pin 的 identity(SPM 包:静态链接或嵌入 framework);
  2. lyrimuse/build.sh 里 `brew install <名字>`(拷进包的外部二进制,现为 media-control);
  3. lyrimuse-collector/go.mod 的 require(直接 + 间接都算,编进二进制的都要声明;现为空,
     collector 零外部依赖、go.sum 是空文件)。
名字在 THIRD_PARTY_LICENSES 里出现一次(不区分大小写)就算声明过;只查"提到没提到",许可证文本
对不对仍靠人。反向(声明了但已经不用)不查:多一条声明没有合规风险。
顺带确认 build.sh 还在拷这个文件 —— 不拷的话上面全部白查。

用法:python3 lyrimuse/scripts/check_third_party_licenses.py(仓库任意位置;退出码 0 通过 / 1 有缺)。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LICENSES = ROOT / "THIRD_PARTY_LICENSES"


def spm_identities():
    doc = json.loads((ROOT / "lyrimuse/Package.resolved").read_text(encoding="utf-8"))
    # v2/v3 顶层 pins;v1 在 object.pins,identity 叫 package。
    pins = doc.get("pins") or (doc.get("object") or {}).get("pins") or []
    return [(pin.get("identity") or pin.get("package"), "lyrimuse/Package.resolved")
            for pin in pins if pin.get("identity") or pin.get("package")]


def brew_installs():
    found = []
    for line in (ROOT / "lyrimuse/build.sh").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for m in re.finditer(r"\bbrew install\s+([A-Za-z0-9._@/+-]+)", stripped):
            found.append((m.group(1).split("/")[-1], "lyrimuse/build.sh"))
    return found


def go_requires():
    found, in_block = [], False
    for line in (ROOT / "lyrimuse-collector/go.mod").read_text(encoding="utf-8").splitlines():
        code = line.split("//", 1)[0].strip()
        if not code:
            continue
        if code.startswith("require ("):
            in_block = True
            continue
        if in_block and code == ")":
            in_block = False
            continue
        m = re.match(r"^(?:require\s+)?(\S+)\s+v\S+$", code)
        if m and (in_block or code.startswith("require ")):
            found.append((m.group(1), "lyrimuse-collector/go.mod"))
    return found


def build_copies_licenses():
    for line in (ROOT / "lyrimuse/build.sh").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("cp ") and "THIRD_PARTY_LICENSES" in stripped and "Contents/Resources" in stripped:
            return True
    return False


def main():
    if not LICENSES.exists():
        print(f"\u2717 找不到 {LICENSES}")
        return 1
    text = LICENSES.read_text(encoding="utf-8").lower()
    # 同一个名字可能多处出现(build.sh 的 brew install 本体 + 失败提示里的同一句),去重保留首次顺序。
    deps, seen = [], set()
    for name, src in spm_identities() + brew_installs() + go_requires():
        if name.lower() not in seen:
            seen.add(name.lower())
            deps.append((name, src))
    missing = [(name, src) for name, src in deps if name.lower() not in text]
    ok = True
    if not build_copies_licenses():
        ok = False
        print("\u2717 lyrimuse/build.sh 不再把 THIRD_PARTY_LICENSES 拷进 Contents/Resources/ —— "
              "「第三方许可」那一行只能退到 GitHub,随附条款就不满足了")
    if missing:
        ok = False
        print("\u2717 以下依赖没在 THIRD_PARTY_LICENSES 里声明(补一条:名字、来源链接、许可证、随附全文):")
        for name, src in missing:
            print(f"    {name}  \u2190 {src}")
    if ok:
        names = ", ".join(name for name, _ in deps)
        print(f"\u2713 THIRD_PARTY_LICENSES 覆盖 {len(deps)} 个随包分发的依赖:{names}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

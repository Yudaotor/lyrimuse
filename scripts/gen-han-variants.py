#!/usr/bin/env python3
"""从上游数据推出「异体字 → 大陆规范字」表,生成 Go 和 Swift 两侧共用的同一份映射。

用法:
    python3 scripts/gen-han-variants.py            # 重新生成两份产物
    python3 scripts/gen-han-variants.py --check     # 只校验产物是不是最新(selftest/CI 用)
    python3 scripts/gen-han-variants.py --unihan-dir <目录>   # 用本地已解压的 Unihan 数据

产物(都要连同本脚本一起提交):
    lyrimuse-collector/dictionary/HanVariants.txt              ← collector 用 //go:embed 读
    lyrimuse/Sources/LyrimuseCore/Lyrics/HanVariantsTable.swift ← App 侧编译进去

═══ 为什么要有这一层 ═══

繁简转换(Go 用 OpenCC 词库、Swift 用 ICU)覆盖不到**异体字**:大陆《第一批异体字整理表》
淘汰、港台仍在用的那批字。它们不是某个简体字的"繁体",所以两个引擎都原样放过去,后果是:
  - 搜索(Go):2026-09-03 用户报「妳聽得到」只搜出 1 个候选 —— 转换后搜索词是「妳听得到」,
    而网易云/QQ/酷狗曲库里这首叫「你听得到」,三家一条都匹配不上(实测 A/B 见 09 章);
  - 显示(Swift):2026-08-22 用户报「开了简体还是看到繁体」——《开不了口 (Live)》里 ICU 把
    37 种字符全转对了,只剩「妳」没动,出现 21 次。

═══ 为什么不手工维护字表 ═══

用户 2026-09-03 的原话:「你要做成通用逻辑,后续遇到这种字的问题都要可以解决,不要通过手动
维护一个表的方式,而且 swift 和 go 都使用同一套逻辑尽量」。手工表的毛病 collector 里
`toSimplified` 的注释早就写过:"覆盖面依赖'撞见一个字才补一个字'的被动积累"。所以这里的表
是**推出来的**:

  1. 只考虑 Unihan `kUnihanCore2020` **不含 G**(大陆通用集之外)的字 —— 大陆的曲库/歌词
     不会用这些字形,它们正是会把搜索和显示卡住的那一类。本身在 G 里的字一律不动。
  2. 目标字按这个优先级取,取到就停:
       a. OpenCC 的 TSCharacters(项目已内嵌的那份繁简单字表)——中文界最权威的对照数据;
       b. Unihan `kSimplifiedVariant`(有向、就是"这个字的简化字");
       c. Unihan `kSpecializedSemanticVariant`(窄义同义变体);
       d. Unihan `kSemanticVariant`(同义变体)。
     b/c/d 的候选先按"目标必须在 G 集"过滤;剩下多个时用 `kGradeLevel`(港澳小学学段字表,
     Unihan 里唯一可用的"常用度"信号)收成一个,仍然多个就**放弃这个字**——宁可不折叠,
     也不猜。「妳」正是靠这一步定下来的:它的 kSpecializedSemanticVariant 是
     {你, 您, 祢, 裮},其中只有「你」有 kGradeLevel(=1)。
  3. 目标字必须在 G 集里(不然就是把一个没人用的字换成另一个没人用的字)。
  4. 最后只保留**至少填了一个引擎的缺口**的条目(见下面 gap 列):两个引擎都能自己转的字
     留在表里是死条目,只会让人误以为这一层在负责它。
  5. `scripts/han-variant-overrides.txt` 里的人工补丁最后合入,可以补(上游确实没有关系的字)
     也可以**否决**(目标写 `-`)。每一行都要写清理由——那份文件本身就是这道纪律的载体。

⚠️ **只做"异体 → 大陆规范"这一个方向,绝不反向**:简体只有「你」,转繁体时无从判断该写
「你」还是「妳」,那要猜被称呼者的性别,猜错就是改写歌词(同「他/她/它」)。

⚠️ 产物里**不写生成时间**,只写 Unicode 版本:带时间戳的话 `--check` 每次都会判"不一致"。
"""
import argparse
import collections
import io
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS_CHARACTERS = os.path.join(ROOT, "lyrimuse-collector", "dictionary", "TSCharacters.txt")
OVERRIDES = os.path.join(ROOT, "scripts", "han-variant-overrides.txt")
ICU_PROBE = os.path.join(ROOT, "scripts", "han-icu-probe.swift")
OUT_TXT = os.path.join(ROOT, "lyrimuse-collector", "dictionary", "HanVariants.txt")
OUT_SWIFT = os.path.join(ROOT, "lyrimuse", "Sources", "LyrimuseCore", "Lyrics", "HanVariantsTable.swift")

# Unihan 整包(约 8.5MB)。只取其中两份文本,用完不留在仓库里——它是上游数据,不是我们的资产;
# 重新生成时按需下载,离线的话用 --unihan-dir 指本地解压目录。
UNIHAN_URL = "https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip"
NEEDED = ("Unihan_Variants.txt", "Unihan_DictionaryLikeData.txt")


def load_unihan(unihan_dir):
    """返回 (variants, core2020, gradeLevel, unicode_version)。"""
    blobs = {}
    if unihan_dir:
        for name in NEEDED:
            path = os.path.join(unihan_dir, name)
            with open(path, encoding="utf-8") as f:
                blobs[name] = f.read()
    else:
        print("下载 %s …" % UNIHAN_URL, file=sys.stderr)
        with urllib.request.urlopen(UNIHAN_URL, timeout=120) as resp:
            data = resp.read()
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for name in NEEDED:
                blobs[name] = z.read(name).decode("utf-8")

    version = "unknown"
    m = re.search(r"^#\s*Unicode Version:?\s+(\S+)", blobs["Unihan_Variants.txt"], re.M)
    if m:
        version = m.group(1)

    variants = collections.defaultdict(lambda: collections.defaultdict(list))
    for line in blobs["Unihan_Variants.txt"].splitlines():
        if not line.startswith("U+"):
            continue
        cp, field, vals = line.split("\t", 2)
        for token in vals.split():
            # 值形如 "U+4F60" 或 "U+4F60<kMatthews"(带出处标注),只要码点。
            target = token.split("<")[0]
            if target.startswith("U+") and target != cp:
                variants[cp][field].append(target)

    core, grade = {}, {}
    for line in blobs["Unihan_DictionaryLikeData.txt"].splitlines():
        if not line.startswith("U+"):
            continue
        cp, field, val = line.split("\t", 2)
        if field == "kUnihanCore2020":
            core[cp] = val
        elif field == "kGradeLevel":
            grade[cp] = int(val)
    return variants, core, grade, version


def load_opencc_chars():
    """OpenCC 繁→简单字表:繁体字 → 第一个简体候选(取第一候选的规则同 t2s.go)。"""
    table = {}
    with open(TS_CHARACTERS, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0]:
                table[parts[0]] = parts[1].split()[0]
    return table


def load_overrides():
    """人工补丁:{变体: (目标 or None 表示否决, 理由)}。"""
    adds, vetoes = {}, {}
    with open(OVERRIDES, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            src, dst = parts[0].strip(), parts[1].strip()
            reason = parts[2].strip() if len(parts) > 2 else ""
            if dst == "-":
                vetoes[src] = reason
            else:
                adds[src] = (dst, reason)
    return adds, vetoes


def icu_converts(chars):
    """实测 ICU 对每个字转成什么(见 scripts/han-icu-probe.swift)。返回 {字: icu 产物}。"""
    with tempfile.TemporaryDirectory() as tmp:
        binary = os.path.join(tmp, "han-icu-probe")
        subprocess.run(["swiftc", "-O", "-o", binary, ICU_PROBE], check=True,
                       stdout=subprocess.DEVNULL)
        proc = subprocess.run([binary], input="\n".join(chars), capture_output=True,
                              text=True, check=True)
    out = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            out[parts[0]] = parts[1]
    return out


def derive():
    args = parse_args()
    variants, core, grade, version = load_unihan(args.unihan_dir)
    opencc = load_opencc_chars()
    adds, vetoes = load_overrides()

    def ch(cp):
        return chr(int(cp[2:], 16))

    def cp_of(c):
        return "U+%04X" % ord(c)

    in_g = lambda cp: "G" in core.get(cp, "")
    common = lambda cp: cp in grade

    def pick_semantic(cands):
        """候选先留大陆通用字;多于一个时用 kGradeLevel 收成一个,仍然多个就放弃。"""
        c = sorted({x for x in cands if in_g(x)})
        if len(c) > 1:
            graded = [x for x in c if common(x)]
            if len(graded) == 1:
                c = graded
        return c[0] if len(c) == 1 else None

    picked = {}
    universe = sorted(set(variants) | {cp_of(c) for c in opencc})
    for cp in universe:
        v = ch(cp)
        # 只处理 Unihan 明确标了区域集、且不含 G 的字(见文件头规则 1)
        if cp not in core or in_g(cp):
            continue
        if v in opencc and in_g(cp_of(opencc[v])):
            picked[v] = (opencc[v], "opencc")
            continue
        fields = variants.get(cp, {})
        simplified = sorted(set(fields.get("kSimplifiedVariant", [])))
        if len(simplified) == 1 and in_g(simplified[0]):
            picked[v] = (ch(simplified[0]), "unihan-simplified")
            continue
        target = pick_semantic(fields.get("kSpecializedSemanticVariant", []))
        if target:
            picked[v] = (ch(target), "unihan-specialized")
            continue
        target = pick_semantic(fields.get("kSemanticVariant", []))
        if target:
            picked[v] = (ch(target), "unihan-semantic")

    for src, (dst, _reason) in adds.items():
        picked[src] = (dst, "override")

    # 目标字再过一遍 OpenCC 单字表,直到它自己也不会被繁简转换改动为止。
    # ⚠️ 这一步是 collector 侧 hanvariants_test.go 的不变量逼出来的(2026-09-03):推导会给出
    # 「寗→甯」「尅→剋」「亁→乾」这种目标——甯/剋/乾 自己还会被 OpenCC 转成 宁/克/干,于是
    # 这一层的产物不是最终形态。而它挂在**单字兜底分支**上、每个位置只跑一遍,不会再转第二次,
    # 结果就停在半路。所以在生成时就把目标推到不动点,别指望运行时多转一轮。
    for src, (dst, source) in list(picked.items()):
        seen = {dst}
        while dst in opencc:
            nxt = opencc[dst]
            if nxt in seen:  # 理论上不会有环,真有就停在这里,别死循环
                break
            dst = nxt
            seen.add(dst)
        picked[src] = (dst, source)

    # 哪些条目真的填了缺口:Go 侧看 OpenCC 转不转,Swift 侧实测 ICU 转不转。
    icu = icu_converts(sorted(picked))
    rows = []
    for v in sorted(picked):
        target, source = picked[v]
        if v in vetoes:
            continue
        gaps = []
        if icu.get(v, v) == v:
            gaps.append("icu")
        if v not in opencc:
            gaps.append("opencc")
        if not gaps:
            continue  # 两个引擎都自己能转,留着只会误导
        rows.append((v, target, source, "+".join(gaps)))
    return rows, version, len(picked), vetoes


def render_txt(rows, version):
    by_source = collections.Counter(r[2] for r in rows)
    by_gap = collections.Counter(r[3] for r in rows)
    lines = [
        "# 异体字 → 大陆规范字。**生成产物,不要手改**。",
        "# 生成:python3 scripts/gen-han-variants.py(推导规则、为什么不手工维护见那个脚本的头注)",
        "# 数据来源:Unicode Unihan %s(kUnihanCore2020/kGradeLevel/k*Variant)+ OpenCC TSCharacters" % version,
        "#          + scripts/han-variant-overrides.txt(人工补丁,每行带理由)",
        "# 列:变体字<TAB>大陆规范字<TAB>数据依据<TAB>填的是谁的缺口(icu=Swift 侧 / opencc=Go 侧)",
        "# 条目 %d;依据分布 %s;缺口分布 %s" % (
            len(rows),
            " ".join("%s=%d" % (k, v) for k, v in sorted(by_source.items())),
            " ".join("%s=%d" % (k, v) for k, v in sorted(by_gap.items()))),
    ]
    for v, target, source, gap in rows:
        lines.append("%s\t%s\t%s\t%s" % (v, target, source, gap))
    return "\n".join(lines) + "\n"


def render_swift(rows, version):
    variants = "".join(r[0] for r in rows)
    targets = "".join(r[1] for r in rows)
    icu_gap = "".join(r[0] for r in rows if "icu" in r[3])
    return '''// 由 scripts/gen-han-variants.py 生成 —— **不要手改这个文件**。
//
// 数据来源:Unicode Unihan {version}(kUnihanCore2020 / kGradeLevel / k*Variant)+ OpenCC
// TSCharacters + scripts/han-variant-overrides.txt。推导规则和"为什么不手工维护字表"写在
// 生成器头注里;同一次生成还写了 lyrimuse-collector/dictionary/HanVariants.txt(collector 侧
// 读那一份),两边**是同一份数据**,selftest 有一条断言按那个 .txt 逐字核对这里的表。
//
// 表用两条等长字符串存、加载时 zip 成字典:{count} 条的字典字面量会让 Swift 的类型检查
// 变得很慢,而这样编译期只有两个字符串常量。
enum HanVariantsTable {{
    /// 变体字(与 standardForms 逐位对应)
    static let variantForms = "{variants}"
    /// 大陆规范字
    static let standardForms = "{targets}"
    /// 其中"ICU 的 Traditional-Simplified 确实不转"的那些变体字 —— 生成时实测出来的
    /// (见 scripts/han-icu-probe.swift)。只有这一批在 App 侧真的会生效,selftest 里那条
    /// "整条转换链的产物必须等于表里的目标字"的强断言只对它们成立:其余条目 ICU 自己就
    /// 转掉了(它们留在表里是为 collector 侧的 OpenCC 缺口服务)。
    static let icuGapVariants = "{icu_gap}"

    static let toSimplified: [Character: Character] = {{
        var map: [Character: Character] = [:]
        map.reserveCapacity({count})
        for (v, s) in zip(variantForms, standardForms) {{ map[v] = s }}
        return map
    }}()

    static let icuGaps: Set<Character> = Set(icuGapVariants)
}}
'''.format(version=version, variants=variants, targets=targets, icu_gap=icu_gap, count=len(rows))


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--unihan-dir", help="已解压的 Unihan 数据目录(缺省时联网下载)")
    p.add_argument("--check", action="store_true", help="只校验产物是否最新,不写文件")
    return p.parse_args()


def main():
    args = parse_args()
    rows, version, considered, vetoes = derive()
    txt, swift = render_txt(rows, version), render_swift(rows, version)
    if args.check:
        bad = False
        for path, want in ((OUT_TXT, txt), (OUT_SWIFT, swift)):
            got = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if got != want:
                print("过期: %s(重新跑一次 scripts/gen-han-variants.py)" % path)
                bad = True
        if bad:
            sys.exit(1)
        print("产物是最新的:%d 条(Unihan %s)" % (len(rows), version))
        return
    open(OUT_TXT, "w", encoding="utf-8").write(txt)
    open(OUT_SWIFT, "w", encoding="utf-8").write(swift)
    print("Unihan %s:考察 %d 个非通用字,写出 %d 条(否决 %d 条)" %
          (version, considered, len(rows), len(vetoes)))
    print("  ->", OUT_TXT)
    print("  ->", OUT_SWIFT)


if __name__ == "__main__":
    main()

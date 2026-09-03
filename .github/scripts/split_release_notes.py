#!/usr/bin/env python3
"""把双语（英中对照）发布日志拆成单语言的、真正排版过的 HTML，喂给 Sparkle
（appcast 的 <description xml:lang> 内嵌，或 <sparkle:releaseNotesLink> 资产）。

输入格式就是本仓 RELEASE_NOTES_v*.md / tag 注释的既有约定：
  - 开头若干个空行分隔的段落：英文段和中文段各自成段；
  - 小节标题形如 "New / 新功能"（英文 / 中文，按**最后一个** " / " 切开——
    "Last.fm & scrobbling / Last.fm 与打卡" 这种左半边自带斜杠的也能对付）；
  - 每个 bullet 以 "- " 开头，先若干行英文、后若干行中文（中文行以两空格缩进续行）；
  - 下载表格 / 链接行本身就是双语混排或纯链接，两个语言版本都原样保留。

行归属靠 CJK 字符占比判断（>0.25 算中文行）。英文行里夹着的少量中文词
（"The One演唱会"、演唱会/现场/音乐会 这类例子）占比远低于阈值，不会误判——
这是对本仓行文习惯的经验阈值，不是通用断言；改了行文风格要回来核这个阈值。

渲染（2026-09-03，用户看到 Sparkle 弹窗里 <pre> 排版报的）：Sparkle 的说明
WebView 渲染 HTML 但**不渲染 markdown**，而 notes 源文件是 76 列硬换行的
markdown——直接塞 <pre> 会得到"句子中间断行 + 裸 **粗体** [链接]()"的观感。
所以这里把 markdown 转成真 HTML：标题/列表/加粗/链接/表格，段与 li 内的硬换行
按 CJK 规则合并（两侧任一是 CJK 就直接拼接，否则补空格——中文句子拼接时不能
凭空多出空格）。

用法：split_release_notes.py NOTES.md OUT_DIR
产出：OUT_DIR/notes.{en,zh-Hans}.html（自包含页面：内嵌 CDATA 或挂资产均可用）。
出错宁可整体失败也不出半截文件（CI 里失败就退回内嵌单份 description 的老路，
所以这里的非零退出码是安全阀，不是事故）。
"""
import html
import pathlib
import re
import sys


def cjk_ratio(line: str) -> float:
    chars = [c for c in line if not c.isspace()]
    if not chars:
        return 0.0
    cjk = sum(1 for c in chars if "一" <= c <= "鿿" or "　" <= c <= "〿" or "＀" <= c <= "￯")
    return cjk / len(chars)


def is_zh(line: str) -> bool:
    return cjk_ratio(line) > 0.25


HEADER_RE = re.compile(r"^(#*\s*)?\S.* / .+$")


def split_header(line: str):
    """"New / 新功能" -> ("New", "新功能")；按最后一个 " / " 切。"""
    left, right = line.rsplit(" / ", 1)
    if not is_zh(right) or is_zh(left):
        return None
    left_txt = re.sub(r"^#+\s*", "", left)
    return left_txt, right


EN_MARKER = "<!-- lang:en -->"
ZH_MARKER = "<!-- lang:zh-Hans -->"


def split_notes_by_marker(text: str):
    """AGENTS.md「发布」一节约定的显式标记格式：标题行 + <!-- lang:en --> 英文整块 +
    <!-- lang:zh-Hans --> 中文整块。有标记时优先走这里——作者拆的永远比启发式准。
    返回 (en_lines, zh_lines)，没有标记返回 None。"""
    if EN_MARKER not in text or ZH_MARKER not in text:
        return None
    header, rest = text.split(EN_MARKER, 1)
    en_body, zh_body = rest.split(ZH_MARKER, 1)
    header_lines = [ln.rstrip() for ln in header.splitlines() if ln.strip()]
    en = header_lines + [""] + en_body.strip("\n").splitlines()
    zh = header_lines + [""] + zh_body.strip("\n").splitlines()
    return en, zh


def split_notes(text: str):
    """拆成两份"行列表"。小节标题带上 "### " 前缀作标记，供渲染层识别。"""
    en_lines: list[str] = []
    zh_lines: list[str] = []
    bullet_zh_pending: list[str] = []

    def flush_bullet_zh():
        nonlocal bullet_zh_pending
        for i, ln in enumerate(bullet_zh_pending):
            zh_lines.append(("- " if i == 0 else "  ") + ln.strip())
        bullet_zh_pending = []

    in_bullet = False
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        stripped = line.strip()

        if not stripped:
            flush_bullet_zh()
            in_bullet = False
            en_lines.append("")
            zh_lines.append("")
            continue

        if stripped.startswith("|") or stripped.startswith("**Full Changelog**") or stripped.startswith("http"):
            flush_bullet_zh()
            in_bullet = False
            en_lines.append(line)
            zh_lines.append(line)
            continue

        if not line.startswith(" ") and not line.startswith("- ") and " / " in line and HEADER_RE.match(line):
            parts = split_header(line)
            if parts:
                flush_bullet_zh()
                in_bullet = False
                en_lines.append("### " + parts[0])
                zh_lines.append("### " + parts[1])
                continue

        if line.startswith("- "):
            flush_bullet_zh()
            in_bullet = True
            if is_zh(line):
                bullet_zh_pending.append(line[2:])
            else:
                en_lines.append(line)
            continue

        if in_bullet:
            if is_zh(line):
                bullet_zh_pending.append(line)
            else:
                en_lines.append(line)
            continue

        if is_zh(line):
            zh_lines.append(line)
        elif re.match(r"^v\d+\.\d+\.\d+$", stripped):
            en_lines.append(line)
            zh_lines.append(line)
        else:
            en_lines.append(line)

    flush_bullet_zh()
    return en_lines, zh_lines


CJKISH = re.compile(r"[^\x00-\x7f]")


def join_wrapped(parts: list[str]) -> str:
    """合并硬换行：相邻两段的接缝任一侧是非 ASCII（CJK/全角标点）就直接拼，否则补空格。"""
    out = ""
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if not out:
            out = p
            continue
        if CJKISH.match(out[-1]) or CJKISH.match(p[0]):
            out += p
        else:
            out += " " + p
    return out


def inline_md(text: str) -> str:
    """转义后处理行内 markdown：**粗体**、[文字](链接)。"""
    s = html.escape(text, quote=False)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def render_html(lines: list[str], lang: str) -> str:
    body: list[str] = []
    para: list[str] = []
    li: list[str] = []
    in_list = False
    table: list[str] = []

    def flush_para():
        nonlocal para
        if para:
            body.append("<p>" + inline_md(join_wrapped(para)) + "</p>")
            para = []

    def flush_li():
        nonlocal li
        if li:
            body.append("<li>" + inline_md(join_wrapped(li)) + "</li>")
            li = []

    def close_list():
        nonlocal in_list
        flush_li()
        if in_list:
            body.append("</ul>")
            in_list = False

    def flush_table():
        nonlocal table
        if not table:
            return
        rows = []
        for r in table:
            cells = [c.strip() for c in r.strip().strip("|").split("|")]
            if all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
                continue  # |---|---| 分隔行
            rows.append("<tr>" + "".join("<td>" + inline_md(c) + "</td>" for c in cells) + "</tr>")
        body.append("<table>" + "".join(rows) + "</table>")
        table = []

    first = True
    for line in lines:
        stripped = line.strip()
        if not stripped:
            flush_para()
            close_list()
            flush_table()
            continue
        if stripped.startswith("|"):
            flush_para()
            close_list()
            table.append(stripped)
            continue
        flush_table()
        if first and re.fullmatch(r"v\d+\.\d+\.\d+", stripped):
            body.append("<h2>" + html.escape(stripped) + "</h2>")
            first = False
            continue
        first = False
        if stripped.startswith("### "):
            flush_para()
            close_list()
            body.append("<h3>" + inline_md(stripped[4:]) + "</h3>")
            continue
        if line.startswith("- "):
            flush_para()
            flush_li()
            if not in_list:
                body.append("<ul>")
                in_list = True
            li.append(line[2:])
            continue
        if in_list and line.startswith("  "):
            li.append(line)
            continue
        close_list()
        para.append(line)
    flush_para()
    close_list()
    flush_table()

    return (
        f'<!DOCTYPE html>\n<html lang="{lang}"><head><meta charset="utf-8"><style>\n'
        "body{font:13px -apple-system,'PingFang SC',sans-serif;line-height:1.55;margin:14px;color:#333}\n"
        "@media(prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}a{color:#6cf}}\n"
        "h2{font-size:17px;margin:0 0 10px}h3{font-size:14px;margin:16px 0 6px}\n"
        "ul{margin:6px 0;padding-left:20px}li{margin:3px 0}\n"
        "table{border-collapse:collapse;margin:8px 0}td{border:1px solid #8884;padding:4px 8px}\n"
        "</style></head><body>\n" + "\n".join(body) + "\n</body></html>\n"
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    out_dir = pathlib.Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    by_marker = split_notes_by_marker(src)
    en_lines, zh_lines = by_marker if by_marker else split_notes(src)
    en_plain = "\n".join(en_lines)
    zh_plain = "\n".join(zh_lines)
    # 哨兵：两边都必须有实质内容——一边太短就说明输入不是双语对照格式（或者拆分
    # 逻辑坏了），此时拒绝输出让 CI 退回单份 description，比发出去半截强。
    if len(en_plain) < 200 or len(zh_plain) < 200:
        print(f"!! 拆分结果太短 en={len(en_plain)} zh={len(zh_plain)}，拒绝输出", file=sys.stderr)
        return 1
    (out_dir / "notes.en.html").write_text(render_html(en_lines, "en"), encoding="utf-8")
    (out_dir / "notes.zh-Hans.html").write_text(render_html(zh_lines, "zh-Hans"), encoding="utf-8")
    print(f"en {len(en_plain)} chars, zh {len(zh_plain)} chars -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

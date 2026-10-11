#!/usr/bin/env python3
"""把一次发版的英文说明贴到 Discord 服务器的 #announcements（频道 Webhook）。

用法:  discord_release_post.py NOTES.md TAG RELEASE_URL [--dry-run]

Webhook 地址从环境变量 DISCORD_RELEASE_WEBHOOK 读；没设就只打印一行说明、退出 0。
--dry-run 只把要发的 JSON 打到标准输出，不联网，本地核对排版用。

说明正文沿用 split_release_notes.py 的拆法取英文那份，转成 Discord 的 markdown：
小节标题加粗，bullet 的硬换行按同样规则合并，遇到下载表格就停（表格之后是给 Release 页看的）。
embed 的 description 上限 4096 字符，超了按整条截断，末尾补一行指向 Release 页。

Release 是 release.yml 用 GITHUB_TOKEN 发布的，这种发布不会触发别的工作流的 release 事件，
所以这一步只能写在 release.yml 里发布之后，不能拆成单独的 on: release 工作流。
"""
import json
import os
import pathlib
import re
import sys
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from split_release_notes import join_wrapped, split_notes, split_notes_by_marker  # noqa: E402

DESCRIPTION_LIMIT = 4096
EMBED_COLOR = 0xFF2D55


def english_markdown(lines: list[str]) -> list[str]:
    """英文行列表 -> Discord markdown 的块列表（每块是一个标题或一条 bullet）。"""
    blocks: list[str] = []
    item: list[str] = []

    def flush_item():
        nonlocal item
        if item:
            blocks.append("- " + join_wrapped(item))
            item = []

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("|"):
            break
        if not stripped:
            flush_item()
            continue
        if stripped.startswith("### "):
            flush_item()
            blocks.append("**" + stripped[4:] + "**")
            continue
        if line.startswith("- "):
            flush_item()
            item.append(line[2:])
            continue
        if item and line.startswith("  "):
            item.append(line)
            continue
        flush_item()
        # 正文首行的版本号不输出：embed 标题已经写着。
        if blocks or not re.fullmatch(r"v\d+\.\d+\.\d+(-\S+)?", stripped):
            blocks.append(join_wrapped([line]))
    flush_item()
    return blocks


def join_blocks(blocks: list[str]) -> str:
    out = ""
    for b in blocks:
        sep = "\n\n" if b.startswith("**") else "\n"
        out = (out + sep + b) if out else b
    return out


def build_description(blocks: list[str], release_url: str) -> str:
    more = f"\n\n[Full release notes and downloads]({release_url})"
    kept: list[str] = []
    for b in blocks:
        if len(join_blocks(kept + [b])) + len("\n…") + len(more) > DESCRIPTION_LIMIT:
            # 截断处不留底下一条都没有的小节标题。
            while kept and kept[-1].startswith("**"):
                kept.pop()
            return join_blocks(kept) + "\n…" + more
        kept.append(b)
    return join_blocks(kept) + more


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv[1:]
    if len(args) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    notes_path, tag, release_url = args
    src = pathlib.Path(notes_path).read_text(encoding="utf-8")
    by_marker = split_notes_by_marker(src)
    en_lines, _ = by_marker if by_marker else split_notes(src)
    payload = {
        "username": "Lyrimuse",
        "embeds": [{
            "title": f"Lyrimuse {tag}",
            "url": release_url,
            "description": build_description(english_markdown(en_lines), release_url),
            "color": EMBED_COLOR,
        }],
        "allowed_mentions": {"parse": []},
    }
    if dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    webhook = os.environ.get("DISCORD_RELEASE_WEBHOOK", "").strip()
    if not webhook:
        print("DISCORD_RELEASE_WEBHOOK is not set, skipping the Discord announcement")
        return 0
    req = urllib.request.Request(
        webhook,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "lyrimuse-release (github actions)"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(f"Discord announcement posted: HTTP {resp.status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

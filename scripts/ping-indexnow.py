#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把落地页的 URL 提交给 IndexNow,让 Bing 尽快重抓。

    python3 scripts/ping-indexnow.py              # 提交 sitemap 里的全部 URL
    python3 scripts/ping-indexnow.py --dry-run    # 只打印将要提交什么,不发送
    python3 scripts/ping-indexnow.py <URL…>       # 只提交指定的几条

# 为什么 URL 列表要从线上 sitemap 读,而不是写死在这里

落地页加一页时 `sitemap.xml` 本来就必须更新(发版清单里那一条),而写死的名单不会有人
想起来改 —— 于是新页永远不会被推送,且**不报错**,只表现成"那一页在 Bing 里迟迟不出现"。
从 sitemap 读等于让两份名单不可能漂开。

# key 不是密钥

IndexNow 的 key 是**所有权证明**:文件名即 key 本身,而且必须能被搜索引擎公开读到
(`KEY_LOCATION` 现在就返回 200,任何人都能看)。它写在这里不构成凭据泄漏。

key 文件不在主机根目录时,IndexNow 只授权**它所在目录及其子目录**的 URL。
这个站是 GitHub Pages 的项目页,key 放在 `/lyrimuse/` 下,所以授权范围正好是落地页那一层;
脚本会在提交前自己核一遍,越界的 URL 提前报出来,而不是让整批被服务端拒掉。

# 返回码(IndexNow 规范)

    200  已提交
    202  已接收,key 待验证
    4xx  key 或 URL 不合规

非 2xx 一律非零退出 —— 发版流程要能看出这一步失败了,而不是把失败当成功走过去。
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

ENDPOINT = "https://api.indexnow.org/indexnow"
HOST = "yudaotor.github.io"
SITE = "https://yudaotor.github.io/lyrimuse/"
SITEMAP_URL = SITE + "sitemap.xml"
KEY = "4df677cccc6f33d536fceb0d1eb27d24"
KEY_LOCATION = SITE + KEY + ".txt"
TIMEOUT = 20


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "lyrimuse-ping-indexnow"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.status, resp.read()


def sitemap_urls():
    """sitemap 里的 <loc>,按文件里的顺序。"""
    status, body = fetch(SITEMAP_URL)
    if status != 200:
        raise SystemExit(f"读不到 sitemap({SITEMAP_URL} → HTTP {status})")
    root = ET.fromstring(body)
    # sitemaps.org 的命名空间是必带的,用通配符匹配省得硬编码它的版本。
    locs = [e.text.strip() for e in root.iter() if e.tag.endswith("}loc") or e.tag == "loc"]
    if not locs:
        raise SystemExit(f"sitemap 里一个 <loc> 都没有:{SITEMAP_URL}")
    return locs


def check_key_reachable():
    """key 文件必须公开可读且内容等于 key 本身,否则提交必被拒。"""
    try:
        status, body = fetch(KEY_LOCATION)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"key 文件读不到({KEY_LOCATION} → HTTP {e.code})")
    if status != 200:
        raise SystemExit(f"key 文件读不到({KEY_LOCATION} → HTTP {status})")
    got = body.decode("utf-8", "replace").strip()
    if got != KEY:
        raise SystemExit(f"key 文件内容与 KEY 不一致:文件里是 {got!r},脚本里是 {KEY!r}")


def check_in_scope(urls):
    """越出 key 授权目录的 URL 提前拦下来,别让整批提交被拒。"""
    scope = KEY_LOCATION.rsplit("/", 1)[0] + "/"
    bad = [u for u in urls if not u.startswith(scope)]
    if bad:
        raise SystemExit(
            "以下 URL 不在 key 的授权目录 " + scope + " 之内:\n  " + "\n  ".join(bad))


def submit(urls, dry_run):
    payload = {
        "host": HOST,
        "key": KEY,
        "keyLocation": KEY_LOCATION,
        "urlList": urls,
    }
    body = json.dumps(payload, ensure_ascii=False, indent=2)
    if dry_run:
        print(body)
        print(f"\n--dry-run:未发送。真要提交去掉这个参数。({len(urls)} 条)")
        return 0
    req = urllib.request.Request(
        ENDPOINT,
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            status, text = resp.status, resp.read().decode("utf-8", "replace").strip()
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode("utf-8", "replace").strip()
    print(f"HTTP {status}" + (f"  {text}" if text else "  (空响应体,正常)"))
    if 200 <= status < 300:
        print(f"已提交 {len(urls)} 条")
        return 0
    print("提交失败 —— 上面的返回码见本文件头注的返回码表", file=sys.stderr)
    return 1


def main():
    ap = argparse.ArgumentParser(description="把落地页 URL 提交给 IndexNow")
    ap.add_argument("urls", nargs="*", help="只提交这几条;不给就用 sitemap 里的全部")
    ap.add_argument("--dry-run", action="store_true", help="只打印将要提交什么,不发送")
    args = ap.parse_args()

    urls = args.urls or sitemap_urls()
    check_in_scope(urls)
    if not args.dry_run:
        check_key_reachable()
    for u in urls:
        print("  " + u)
    print()
    return submit(urls, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())

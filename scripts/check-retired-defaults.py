#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布版写过的偏好键,删掉以后要登记进 ConfigPortability.obsoleteDefaultsKeys(14 章决策 129)。

没登记的死键留在升级用户的 UserDefaults 里,还会跟着导出的备份和配置文件夹的镜像带到新机器。
做法:每个发布 tag(v*)源码里的 "np:…" 字面量并起来,减去这棵树源码里还出现的(登记进那张表的键也是源码里的
字面量),剩下的就是删了没登记的。只认整串字面量,拼出来的键名(带插值)不算。

用法:在要检查的那棵树的根目录里跑,`--repo` 指向带 tag 的仓库(默认当前目录)。
读不到 tag(导出的快照、浅克隆)时打一行说明、退出 0。
"""
import argparse
import pathlib
import re
import subprocess
import sys

KEY_RE = re.compile(r'"(np:[A-Za-z0-9_.]+)"')
SOURCES = "lyrimuse/Sources"


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def released_keys(repo):
    tags = [t for t in git(repo, "tag", "--list", "v*").split() if t]
    keys = set()
    for tag in tags:
        out = subprocess.run(["git", "-C", repo, "grep", "-ohE", r'"np:[A-Za-z0-9_.]+"', tag, "--", SOURCES],
                             capture_output=True, text=True)
        # git grep 没有命中时退出码 1,不算出错。
        if out.returncode not in (0, 1):
            raise RuntimeError(out.stderr.strip())
        keys.update(KEY_RE.findall(out.stdout))
    return tags, keys


def current_keys(root):
    keys = set()
    for path in (root / SOURCES).rglob("*.swift"):
        keys.update(KEY_RE.findall(path.read_text(encoding="utf-8")))
    return keys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    args = parser.parse_args()
    root = pathlib.Path.cwd()
    try:
        tags, released = released_keys(args.repo)
    except (subprocess.CalledProcessError, RuntimeError, FileNotFoundError) as e:
        print(f"    读不到发布 tag,跳过({e})")
        return 0
    if not tags:
        print("    没有发布 tag,跳过")
        return 0
    missing = sorted(released - current_keys(root))
    if missing:
        print("!! 这些偏好键在发布版里写过、现在源码里没有了,登记进 ConfigPortability.obsoleteDefaultsKeys:", file=sys.stderr)
        for key in missing:
            print(f"   {key}", file=sys.stderr)
        return 1
    print(f"    {len(tags)} 个发布 tag、{len(released)} 个键,删掉的都登记了")
    return 0


if __name__ == "__main__":
    sys.exit(main())

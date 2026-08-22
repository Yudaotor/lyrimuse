# CLAUDE.md

完整约束见 **[AGENTS.md](AGENTS.md)**（同一份内容，那边是 Codex 的入口）。动手前请读一遍。

**改任何功能之前，先看 [docs/features/README.md](docs/features/README.md) 的章节索引，再读对应那一章。**
那 15 章是 as-built 规格：当前行为、边界情况、代码锚点，以及每个「设计决策与已知坑」背后的实测
依据——改之前读了，能省掉重新踩一遍的时间；改完在同一次改动里更新对应章，这是仓库约定。
（这条单独写在这里，是因为 AGENTS.md 提到功能文档已经是最后一节了，只读前半截会完全错过它。）

下面四条是最容易在"没读文档"的情况下踩到的，单独提出来：

1. **Go 命令一律带 `GOTOOLCHAIN=go1.24.4`**。默认的 go 1.21 编出来的二进制在这台机器上
   被 AMFI 拒签、启动即死，而且**看起来像是被测代码自己崩了**（见 AGENTS.md 里的说明）。

2. **不要用 AppleScript / System Events 驱动界面做验证。** 用只读的
   `swift lyrimuse/scripts/check-windows.swift` 和 `screencapture -l <窗口ID>`。
   这个项目为此毁过一次用户数据、误截过一次用户的聊天窗口。

3. **`swift build` 通过不等于装好了。** 真机验证前必须 `cd lyrimuse && ./build.sh`。

4. **所有改动直接做在 `dev` 分支上。** 不要新建 feature 分支，也不要为一次改动开
   `worktree-*` 分支——直接在 `dev` 上改、在 `dev` 上提交。（这个仓库只有作者一个人在
   `dev` 上推进，多开一个分支只会让改动落在他不看的地方、还多一次合并。详见 AGENTS.md
   「提交」一节。）

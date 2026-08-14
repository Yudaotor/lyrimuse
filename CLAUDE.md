# CLAUDE.md

完整约束见 **[AGENTS.md](AGENTS.md)**（同一份内容，那边是 Codex 的入口）。动手前请读一遍。

下面三条是最容易在"没读文档"的情况下踩到的，单独提出来：

1. **Go 命令一律带 `GOTOOLCHAIN=go1.24.4`**。默认的 go 1.21 编出来的二进制在这台机器上
   被 AMFI 拒签、启动即死，而且**看起来像是被测代码自己崩了**（见 AGENTS.md 里的说明）。

2. **不要用 AppleScript / System Events 驱动界面做验证。** 用只读的
   `swift lyrimuse/scripts/check-windows.swift` 和 `screencapture -l <窗口ID>`。
   这个项目为此毁过一次用户数据、误截过一次用户的聊天窗口。

3. **`swift build` 通过不等于装好了。** 真机验证前必须 `cd lyrimuse && ./build.sh`。

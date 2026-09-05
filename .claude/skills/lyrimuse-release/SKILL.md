---
name: lyrimuse-release
description: "lyrimuse 发版 / cut a release — 打 tag、推 Release、更新 appcast 与 Homebrew cask。只在用户明确说「发版 / release vX.Y.Z」时用 /lyrimuse-release 显式触发；正文只是 docs/releasing.md 的目录与硬闸，checklist 本体在那份文档。"
disable-model-invocation: true
---

# lyrimuse 发版

> 本 skill 不复述 checklist。**逐条照 [docs/releasing.md](../../../docs/releasing.md) 的顺序执行**——那份文档每条都带 v1.5.0 实录的坑；规范性约束（分支策略、tag 注释格式）在 [AGENTS.md「提交」](../../../AGENTS.md)。

## 顺序（对应 docs/releasing.md 五节）

1. **写发布日志** `RELEASE_NOTES_v<版本>.md`：范围 = `git diff <上一个 tag>..HEAD`，以 `docs/features` 各章 diff 为查漏主信源；只写用户可感知的变化；双语（显式 `<!-- lang:en -->` / `<!-- lang:zh-Hans -->` 标记或逐条交错，CI 用 `.github/scripts/split_release_notes.py` 拆）。
2. **同步对外物料**：README ×3、截图、`llms.txt`、GitHub About 与 topics、版本号引用——逐关键词 grep 实证，「碰过文件 ≠ 覆盖到位」。
3. **发布前验证**：`ListAgents` 确认没人在写这棵树；collector `go vet` / `go test` / `gofmt -l`；`swift build` + selftest ALL PASS；真机 `./build.sh`；**并看 dev 的 CI 真实结果**；`main` fast-forward 到发布点。
4. **打 tag**：`git tag -a v<版本> <验证过的 commit> -F RELEASE_NOTES_v<版本>.md && git push origin v<版本>`；`gh run watch` 到绿；Release 页 7 个资产齐全；appcast 抽查 `hardwareRequirements` 恰好一个且在 arm64 item 上、分语言说明生效（`.github/scripts/check_appcast.py`）。
5. **发布后**：Homebrew cask（**sha256 取 CI 的 `.sha256` 资产**，本地包哈希不同）；Sparkle 升级链路实测（装回旧版前先备份 `~/.config/lyrimuse`）；issues 逐个收口；「关于」页 App 与 collector 版本号一致。

6. **测试版**走 [docs/releasing.md](../../../docs/releasing.md)「六、发测试版」：tag 带 `-beta.N`，CI 自动标 prerelease、enclosure 指 tag 目录、item 带 beta channel；测试机在「关于 → 更新」开「接收测试版更新」即可收到。不更新 cask、不推进 `main`。

## 硬闸（任何一条不满足就停下问用户）

- 改动不在 `dev` 上，或 `main` 没有 fast-forward 到发布点（AGENTS.md「提交 → 分支策略」）。
- tag 不是 annotated、正文为空、或没有双语（AGENTS.md「提交 → tag annotation」）；形态不是 `vX.Y.Z` / `vX.Y.Z-(alpha|beta|rc).N`（AGENTS.md「提交 → tag 形态」）。
- 本地 selftest 或 collector 测试有 FAIL，或 dev 的 CI 是红的。
- 有别的会话正在这棵树上写文件。

## 偶发

`lyrimuse/package.sh` 的 dmgbuild detach「资源忙」重跑即可；本地验 appcast 用过 `defaults write me.yudaotor.lyrimuse SUFeedURL` 的话验完必须 `defaults delete`（docs/releasing.md 末节「已知偶发与处置」）。

# 发版流程 checklist

> 每一条都来自 v1.5.0（2026-09-03）发版实录——括号里标着当时踩到/差点踩到的坑。
> 顺序执行；「发布后」几步也属于发版的一部分，不做完不算发完。
> 规范性约束（分支策略、tag 注释格式）在 [AGENTS.md「提交」一节](../AGENTS.md)，本文是操作序列。

## 一、写发布日志（`RELEASE_NOTES_v<版本>.md`）

- [ ] **圈定范围＝`git diff <上一个 tag>..HEAD`，以 docs/features 各章的 diff 为查漏主信源。**
      squash 快照提交的 message 不可信——v1.5.0 时新歌词源 kuwo/lyricfind 就藏在一个
      快照提交里没被列出，靠逐章扫文档 diff 才捞回来。
- [ ] **只写「上一个发布版的用户升级后能感知」的变化。** 窗口内加了又改/又删的自我返工不写
      （v1.5.0 例：iCloud 备份自动清理、悬浮窗简繁菜单项可见性）。拿不准就对着上一个 tag
      实证：`git ls-tree <tag> -- <路径>`、`git show <tag>:<文件> | grep <符号>`——
      「某次提交碰过这个文件」不等于「该功能上一版存在」。
- [ ] **口径**：双语对照；每条一句话只写结论，不写前因后果；不写打分算法版本号这类内部编号。
- [ ] **格式两种都行**（CI 的 `split_release_notes.py` 自动拆分并渲染成分语言 HTML）：
      显式标记式（`<!-- lang:en -->` / `<!-- lang:zh-Hans -->` 两个整块）或
      逐条中英交错式（英文行在前、中文行两空格缩进跟随）。改了交错式行文习惯要回脚本核
      CJK 占比阈值。
- [ ] 日志文件本身入库（tag 用 `-F` 引用它）。

## 二、同步对外物料（发布前做完，别拖到发布后）

- [ ] **README ×3**（en / zh-CN / zh-Hant）：标题句、导语、功能列表补新特性。
      **逐个关键词 grep 实证覆盖**（v1.5.0 教训：README「更新过」但网页播放器、多选、
      粤拼三个头牌全都没写进去——碰过文件 ≠ 覆盖到位）。
- [ ] **README 截图**：对照本版功能变化清单列出需重拍的图（v1.5.0 换了 9 张、新增 2 张），
      文件名不变原地替换；注意截图表格是两张 table（3 列形态表 + 2 列大图表），加新图别把
      列数弄不齐。
- [ ] **llms.txt**：简介、来源数、播放器清单、新文档链接。
- [ ] **GitHub About 描述 + topics**：新卖点进描述（含中文关键词段），topics 满 20 上限、
      加新词要同时决定删哪个。
- [ ] **版本号引用核对**：README/FAQ 里「vX.Y.Z 起」这类超前引用要与实际发布版本对齐
      （v1.5.0 前 README 写着从未发布过的「v1.4.1 起」）。

## 三、发布前验证

- [ ] **多会话协调**：`ListAgents` 确认没有别的会话在写这棵树，锁定「不动树」窗口再动手。
- [ ] `GOTOOLCHAIN=go1.24.4 go vet ./... && go test ./...`（collector）。
- [ ] `gofmt -l` 干净——**并且推送后要看 CI 真实结果**：v1.5.0 时 dev 的 CI 已经连红两次
      （11 个文件没 gofmt），本地测试全绿不代表 CI 绿。
- [ ] `swift build` + `lyrimuse-selftest` 全量 ALL PASS（含本地化 parity 守卫）。
- [ ] 真机 `./build.sh` 装机跑过 tip（swift build 通过 ≠ 装好了）。
- [ ] 本地打一份 arm64 测试包在另一台机器过一眼：临时删掉 package.sh 里 intel 变体行
      跑 arm-only；要美化版 dmg 先 `python3 -m pip install --user dmgbuild`。
- [ ] `main` fast-forward 到发布点（惯例是打 tag **前**做）。

## 四、打 tag 发布

- [ ] `git tag -a v<版本> <验证过的 commit> -F RELEASE_NOTES_v<版本>.md && git push origin v<版本>`
      ——tag 显式打在验证过的 commit 上，不是裸 HEAD。
- [ ] `gh run watch` 盯 Release workflow 到绿；确认 Release 页 7 个资产齐全
      （arm64 与 intel 各 zip/dmg/sha256 + appcast.xml）。
- [ ] appcast 抽查：`hardwareRequirements` **恰好一个**且在 arm64 item 上、arm 包在前；
      分语言说明（`<description xml:lang>` 或 releaseNotesLink）生效。

## 五、发布后

- [ ] **Homebrew cask**（Yudaotor/homebrew-lyrimuse）：version + sha256。
      **sha256 必须取 CI 产物的 `.sha256` 资产**——本地打的同名包哈希不同，用错即坏。
- [ ] **Sparkle 升级链路实测**：找一台上一版机器（或本机临时装回上一版）走一次升级。
      装回旧版前**先备份 `~/.config/lyrimuse`**（旧 collector 不认识新字段，存盘会抹掉），
      且别让旧版跑太久。旧版 ad-hoc 包被 Gatekeeper 拦 `open` 是预期——直接跑
      `Contents/MacOS/Lyrimuse` 或右键→打开。
- [ ] **GitHub issues 收口**：本版修复的 issue 逐个回复（感谢 + 指明版本带 Release 链接 +
      一两句修了什么、能对上报告者原话就点名 + 邀请验证/不行就 reopen）→ close as
      **completed**。
- [ ] 设置页「关于」确认 App 与采集服务版本号一致（两个版本号对不上是 15 章记过的真实事故）。

## 已知偶发与处置

- `package.sh` 的 dmgbuild 收尾 detach 偶发「资源忙」（Spotlight 抢挂载点）——重跑即可；
  注意 dmgbuild **运行期失败不会退回 hdiutil**（只有没装才退回），会直接挂掉打包步骤。
- `hdiutil attach` 失败报「资源忙」时先 `hdiutil info` 看是不是上一次挂载残留。
- 本地验 appcast 用过 `defaults write me.yudaotor.lyrimuse SUFeedURL …` 的话，
  验完必须 `defaults delete`，否则所有更新检查静默失败（15 章坑 10）。

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
- [ ] **落地页（gh-pages 分支，yudaotor.github.io/lyrimuse）**：`index.html` 与 `zh/index.html` 的
      JSON-LD `softwareVersion`、正文新特性；`compare/` 两页的「最新发布」行与核实日期；`sitemap.xml`
      的 lastmod。push 后向 `api.indexnow.org/indexnow` 重发四个页面 URL（key 文件已在站点根，
      2026-09-06 首次提交返回 202）。
- [ ] **「N 个歌词源」这类数字全局扫**：源数/播放器数变了（如咪咕 8→9）要横扫所有对外面——
      README×3、llms.txt、docs/lyrics-apps-comparison*、gh-pages 首页与对比页、GitHub About、
      AlternativeTo 条目——v1.5.0 后这些地方到处写着「8 个源」，漏一处就自相矛盾。
- [ ] **README 四张合成大图**（docs/images/hero-*.png）：界面明显变化时用 [docs/heroes/](heroes/README.md)
      的 HTML 源重渲，文件名不变原地替换；gh-pages 的 `assets/img/` 截图副本同步。
- [ ] **第三方条目**（大版本才动）：AlternativeTo 条目、macosmenubar 的管理链接（无账号体系，
      链接即凭证）里的描述与截图；awesome 列表的一句话描述只在头牌卖点变化时提 PR 改。

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

- [ ] `git tag -a v<版本> <验证过的 commit> -F RELEASE_NOTES_v<版本>.md`——tag 显式打在验证过的 commit 上，不是裸 HEAD。
- [ ] **push 前本地预检**：`bash .github/scripts/check_release_tag.sh v<版本>`。CI 构建前跑的就是这一份：形态合法、
      annotated、正文非空、能拆成中英两份（英文 ≥200 字符、中文 ≥80 字符）。本地先过，省得 push 上去才红、删远端 tag 重打。
      不过就 `git tag -d` 改正文重打，别硬推。
- [ ] `git push origin v<版本>`
- [ ] CI 构建前会再跑同一份校验（2026-09-05 起）：`vX.Y.Z` 正式版，`vX.Y.Z-(alpha|beta|rc).N` 测试版（见「六」），
      其它形态、轻量 tag、空正文、拆不出双语的正文都在装工具链之前直接失败，不会出现在 Releases 页。
- [ ] `gh run watch` 盯 Release workflow 到绿；确认 Release 页 7 个资产齐全
      （arm64 与 intel 各 zip/dmg/sha256 + appcast.xml）。
- [ ] appcast 抽查：`hardwareRequirements` **恰好一个**且在 arm64 item 上、arm 包在前；
      分语言说明（`<description xml:lang>` 或 releaseNotesLink）生效。

## 五、发布后

- [ ] **Homebrew cask**（Yudaotor/homebrew-lyrimuse）：version + **两个 sha256**（cask 自
      2026-09-06 起双架构：`sha256 arm:/intel:` 对应 `-macos.zip` 与 `-macos-intel.zip`）。
      **sha256 必须取 CI 产物的两个 `.sha256` 资产**——本地打的同名包哈希不同，用错即坏。
- [ ] **Sparkle 升级链路实测**：找一台上一版机器（或本机临时装回上一版）走一次升级。
      装回旧版前**先备份 `~/.config/lyrimuse`**（旧 collector 不认识新字段，存盘会抹掉），
      且别让旧版跑太久。旧版 ad-hoc 包被 Gatekeeper 拦 `open` 是预期——直接跑
      `Contents/MacOS/Lyrimuse` 或右键→打开。
- [ ] **GitHub issues 收口**：本版修复的 issue 逐个回复（感谢 + 指明版本带 Release 链接 +
      一两句修了什么、能对上报告者原话就点名 + 邀请验证/不行就 reopen）→ close as
      **completed**。
- [ ] 设置页「关于」确认 App 与采集服务版本号一致（两个版本号对不上是 15 章记过的真实事故）。

## 六、发测试版（beta / rc）

> 2026-09-05 起支持（借鉴清单 #32 + 用户拍板的「接收测试版更新」开关）。目的：发一个**只给自己另一台机器试**的版本，
> 全体用户无感。机制与取舍见 15 章决策 11。

- [ ] tag 形态：`v<X.Y.Z>-beta.<N>`（也认 `alpha` / `rc`），N 从 1 起、不带前导零。带 `-` 就自动标 **Pre-release**，
      GitHub 的 `releases/latest` 不含它，正式用户的 appcast 不受影响。
- [ ] 打法与正式版相同：`git tag -a v1.6.0-beta.1 <commit> -F RELEASE_NOTES_v1.6.0-beta.1.md && git push origin v1.6.0-beta.1`。
      日志照写双语——测试机的 Sparkle 弹窗会显示它；push 前同样先过 `check_release_tag.sh`（见「四」）。
- [ ] CI 会做的：Release 标 prerelease；appcast 的 enclosure 指 `releases/download/<tag>/`（不是 latest）；item 带
      `<sparkle:channel>beta</sparkle:channel>`；`sparkle:version` 是四段构建号（beta.N → `X.Y.Z.(100+N)`，唯一定义在
      `lyrimuse/scripts/build-version.sh`）；`check_appcast.py` 四项断言；发布后探活三个下载地址。
- [ ] 测试机收法（二选一）：① 设置 → 关于 → 更新 → 打开「测试版更新」，再点「检查更新…」——App 自己去 GitHub 挑
      版本最高的 Release（含预发布）的 appcast；② 不开开关，直接去 Release 页下载 dmg 手装（只验产物、不验升级链路）。
      **不用再 `defaults write SUFeedURL`**，也就没有 15 章坑 10 那个忘删的风险。
- [ ] 验完：关掉开关即回正式频道。已装的测试版不会自动退回，等下一个版本号更高的正式版（同号正式版 `v1.6.0`
      的构建号 1000 > beta 的 100+N，会正常被推到）。
- [ ] 不要做的：不要给测试版更新 Homebrew cask（cask 只跟正式版）；不要在测试版 tag 上 fast-forward `main`
      （main 只在正式发版推进）。
- ⚠️ 版本比较的坑：Sparkle 的 `SUStandardVersionComparator` 实测把 `-` 后面的全部忽略（`1.6.0-beta.1 == 1.6.0`、
  `beta.2 == beta.1`），所以展示版本和构建号必须分开；构建号规则只有 `build-version.sh` 一份，selftest update-channel 组
  拿 Core 的 `ReleaseVersion` 交叉校验。

## 已知偶发与处置

- `package.sh` 的 dmgbuild 收尾 detach 偶发「资源忙」（Spotlight 抢挂载点）——重跑即可；
  注意 dmgbuild **运行期失败不会退回 hdiutil**（只有没装才退回），会直接挂掉打包步骤。
- `hdiutil attach` 失败报「资源忙」时先 `hdiutil info` 看是不是上一次挂载残留。
- 本地验 appcast 用过 `defaults write me.yudaotor.lyrimuse SUFeedURL …` 的话，
  验完必须 `defaults delete`，否则所有更新检查静默失败（15 章坑 10）。

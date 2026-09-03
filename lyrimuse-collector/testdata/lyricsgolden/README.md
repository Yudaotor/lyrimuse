# 歌词搜索回归金标集(lyrics golden corpus)

一首真实的歌、一组真实的各源原始应答、一个已确认正确的结论——每类一个样本,守住
「改了打分/守卫之后,这一类歌还选得对」。跑法就是普通 `go test`:

```sh
GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsGolden|TestGolden' -v .
```

四个测试,全部默认开启:

| 测试 | 守什么 |
|---|---|
| `TestLyricsGolden` | 每个样本:冠军 / 每条候选判决 / 纯音乐标记(语义硬断言)+ 名次、分数、全部分项、逐字/译文/罗马音有无(快照) |
| `TestLyricsGoldenCategoryCoverage` | `goldenRequiredCategories` 每一类至少被一个样本**体现**(按 `goldenCategoryCheck` 判,不按标签) |
| `TestLyricsGoldenWinnersAreIndependentlyJustified` | 每个样本的冠军用样本自己的数据重过一遍独立正确性判据(见下「怎么算"确认正确"」) |
| `TestLyricsGoldenFixturesAreScrambled` | 样本里没有明文歌词(见下「为什么样本是乱码」) |
| `TestGolden*`(`lyricsgolden_scramble_unit_test.go`) | 置乱器自身:双射、保形、结构段原样、置乱前后打分结果逐项相同 |

跑的是**生产同一份代码**:`rankLyricSourceResults`(enrich.go,原 `scoreAndSort` 闭包提出来的纯函数)
+ `pickLyricCandidate`。测试里没有第二份打分骨架。

## 改了打分之后

1. 先跑上面那条命令。红了看输出:`[语义]` 行是冠军/判决变了,`[快照]` 行是分数/分项变了。
2. 变化是有意的(比如调了一档权重)→ 重生成期望,然后**看 git diff** 逐首确认哪一项动了:

   ```sh
   LYRICS_GOLDEN_UPDATE=1 GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsGolden$' .
   ```

3. 有样本的**冠军/判决**变了(`[语义]`),UPDATE 会拒绝改写——这是刻意的:换冠军等于"这首歌以后显示
   另一份歌词",必须逐首点头。确认之后:

   ```sh
   LYRICS_GOLDEN_UPDATE=1 LYRICS_GOLDEN_ACCEPT_SEMANTIC=<样本id,样本id>  GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsGolden$' .
   ```

   (`all` 接受全部——只在你真的逐首看过之后用。)
4. 提交时把样本 JSON 的 diff 一起提交;commit message 里写清哪些歌为什么换了。

## 加一类 / 加一首

新判据、新修的一类真实错配 → `goldenRequiredCategories`(lyricsgolden_test.go)加一行,`goldenCategoryCheck`
加一条"这一类的样本必须体现什么"(有候选吃到某项 / 有候选被某条 reject / 冠军带某项……),再采一首:

```sh
LYRICS_GOLDEN_CAPTURE=1 \
LYRICS_GOLDEN_KEY='歌手|歌名|专辑' \            # enrich 缓存里的 key,原样
LYRICS_GOLDEN_ID=<kebab-case 文件名> \
LYRICS_GOLDEN_CATEGORY=<类别键> \
LYRICS_GOLDEN_NOTE='为什么挑这首、它守什么' \
[LYRICS_GOLDEN_PLAYER=com.netease.163music] \   # 这一刻"在放"的播放器,同源 +250 的判据;缺省不加分
GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsGoldenCapture$' -v .
```

采集器联网跑一次真实检索,写入前过四道闸,任一不过就不写(见 `lyricsgolden_capture_test.go` 头注):
可回放(单轮回放冠军 = 联网完整流程冠军)、独立判据成立(见下)、置乱保形(置乱前后打分逐项相同)、
样本自洽(读回来再跑一遍 diff 为零)。再加一道类别校验:样本必须真的体现它声称的类别。
**没有 FORCE**:有争议的不采,换一首。

挑歌的原则:**这一类最容易翻盘的那首**(冠亚军分差小、正好踩在阈值边上),不是最"典型"的那首。
样本的 `note` 里写清这一点。

## 怎么算"确认正确"——不信缓存

缓存里那份是上一版规则选出来的,采集时就撞到两条错的(《低潮期》是 30 秒 5 行的残片;《公园 (Live版)》
是另一场演唱会)。所以冠军要过一组**能从样本自己重算**的独立判据(`goldenLabelEvidence`,写在样本的
`label_evidence` 里;`goldenJudgeEvidence` 是闸):

| 判据 | 要求 | 证明什么 |
|---|---|---|
| `consensus_peers` | ≥1(单候选例外) | 至少两个互不相干的平台给出同一份正文——不是串了别的歌 |
| `title_accepted` | 真 | 冠军自报歌名过 `lyricTitleAccepted`(不认子串) |
| `version_tags_ok` | 真 | 版本限定词一致、不是另一场演出 |
| `source_duration_delta_pct` | ≤3%(单候选 ≤1%;没自报的放行) | 同一次录音 |
| `lyrics_end_secs` / `coverage_pct` | 末句 ≤ 曲长+5s、覆盖 ≥50%(单候选 ≥70%) | 不是残片、不是完整版配了精简曲目 |
| `album_score` | 本地是现场专辑时 >0 | 同一场演出 |
| `live_mismatch` | 假 | 两边 live 声明对称——按 `albumHasLiveMarker` 连拉丁 live/concert 也认,比打分层严 |
| `cache_agreement` | 不是 `differs` | 只作旁证:缓存那份跟冠军不是同一份 = 有争议 |

采集器还会把冠军正文头尾各 4 行**明文**打到终端(不入样本),采集的人要自己看一眼像不像这首歌。

## 为什么样本是乱码

01 章「许可、版权与对外请求」写的是「歌词归权利人,本项目不托管、不转发、不再分发」——真实歌词正文
进 git 就违背这一条。所以样本里的歌词/逐字/译文/罗马音全部经过 `scrambleLyricRound` 的**保形置乱**:
同一首内一致的字符双射,汉字→CJK 扩展 A 区、拉丁→a–z 置换(保大小写)、假名/谚文块内置换;时间戳、
标点、数字、元数据标签、署名行、演唱者标签、纯音乐占位原样。打分读到的每个特征(时间戳密度、末句
时刻、行数、汉字/假名占比、3-gram 共识、署名结构)置乱前后逐位相同——这是**被采集闸 3 验证**的,
不是被相信的。所以:

- 样本文本看不懂是预期,别"修";
- 标题 / 歌手 / 专辑 / 封面 URL / 自报时长是元数据,原样保留,人能凭它们认出样本是哪首歌;
- `TestLyricsGoldenFixturesAreScrambled` 用「置乱段里出现了基本区汉字」当探针,手工往样本里塞明文会红。

## 第二层:检索层(`search/`)

打分层守"拿到最终候选后怎么挑",`search/` 守再往前一步——一个源在**自己的搜索结果**里该选谁
(`lyricsgolden_search_test.go`)。四个源各一个纯函数:netease `neteasePickSong`、qq `qqCollectCandidates` +
`qqPickCandidateWithAlbum` / `qqPickCandidate`、kugou `pickKugouSearchCandidate`、lrclib
`pickLRCLIBSearchResultDetailed`。样本是搜索结果的**元数据**(不是歌词,不用置乱;只有 lrclib 的结果带正文,
照上面的规矩置乱)+ 本地查询词 + 期望挑中谁。

```sh
LYRICS_SEARCH_GOLDEN_CAPTURE=1 LYRICS_GOLDEN_KEY='歌手|歌名|专辑' LYRICS_GOLDEN_ID=<前缀> \
[LYRICS_GOLDEN_NOTE='…'] GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsSearchGoldenCapture$' -v .
```

一次联网检索给四个源各写一份 `<前缀>-<源>.json`(该源这次没搜到就跳过)。网易云/酷狗按标题变体查多次,
取"选出了结果"的批次里条目最多的一批。挑选结果要过 `goldenJudgeSearchPick`:歌名过闸、歌手沾边
(qq loose 档口径)、自报时长 ≤3%、版本一致、live 对称;**选空**的样本要求这批里确实没有站得住的候选。
不过就不写——那往往正是检索层放行了错版本、靠打分层救回的地方,记在 09 章。

更新口径与第一层相同:`LYRICS_GOLDEN_UPDATE=1`,挑选结果变了要 `LYRICS_GOLDEN_ACCEPT_SEMANTIC=<样本id>`。
覆盖契约:四个源各 ≥3 个样本,"选空"负样本全体 ≥2。

## 文件结构

`<id>.json`,字段见 `goldenFixture`(lyricsgolden_test.go):`query`(发给各源的查询词,已 toSimplified)/
`settings`(译文语言、来源开关、挑选模式、播放器、歌手中文别名提示——打分会偷读的全部包级状态)/
`sources`(各源原始应答,`lyricSourceResult` 逐字段;netease 的在 `netease` 子对象,amll 的在 `amll`)/
`expect`(冠军、判决、名次与分项快照、冠军正文指纹)。

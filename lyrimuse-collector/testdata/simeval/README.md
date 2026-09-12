# 歌词打分的反事实评测(simeval)

改 `scoreLyricCandidate` 的任何权重/判定前,先用真实曲库样本量化「这个改动会让多少首歌
换冠军、换对几个换错几个」,别拍脑袋定分值。方法学沿用 2026-08-09 删掉来源先验分那轮:
**量尺必须独立于被测系统**。

## 一、建样本(约 20 分钟,大部分时间在等五个源)

```sh
python3 build_dataset.py    # 歌词文件夹 ∩ ListenBrainz 真实时长 → dataset.json
python3 run_searches.py     # 每首跑一遍 collector search-lyrics → simruns/*.json
```

- 曲目与"当前流水线选了哪个源"来自 `~/.config/lyrimuse/lyrics/*.lrc` 的 6 字段头部;
- **真实时长**取自 ListenBrainz 听歌记录里 collector 自己上报的 `duration_ms`——它独立于
  任何歌词源,这是量尺不被污染的关键;
- `run_searches.py` 限并发 3(防源站风控),已跑过的曲目会跳过,可中断续跑。

两个脚本默认把产物写在**自己所在目录**,把它们连同产物放在临时目录里跑也行——下面的
`SIMEVAL_DATA` 指到哪个目录都可以。

## 二、跑评测

```sh
SIMEVAL_DATA=<放着 simruns/ 的目录> go test -run TestSimEval -v .
```

不设 `SIMEVAL_DATA` 时整个测试跳过,不影响日常 `go test`。评测器会:

1. 用**包内真实 helper**(albumScore/versionTagsIn/scoreLyricCandidateDetailed…)重算基线,
   维度实现与生产代码零漂移——这是它区别于"另写一份打分"的全部价值,别在里面重抄实现;
2. 对每个待评维度单独消融,输出 `counterfactual_report.json`(逐条翻盘 + 三态判定);
3. 拿 `golden_shipped.json` 逐首校验当前引擎的冠军,防实现漂移。

## 三、量尺(三选一,按维度挑,禁止自证)

- **内容多数派**:候选间正文 3-gram Jaccard 聚类,多数派为准;
- **时长判定**:真实时长 vs 末句时间戳;
- **手选金标签**:enrich 缓存里 `manual_lyrics=true` 的条目,用户亲自选过的,最硬。
  **金标签零回归是合入硬闸。**

评测某维度时,与它同源的量尺必须停用(例:评"跨源正文共识"时不许用内容多数派量尺)。

## 四、黄金参照

`golden_shipped.json` 记着**某一份样本快照**上的逐首冠军,带 fingerprint。样本重采后
指纹对不上,断言自动跳过并提示;确认引擎无误后重生成:

```sh
SIMEVAL_DATA=<目录> SIMEVAL_WRITE_GOLDEN=1 go test -run TestSimEval .
```

数据本身(simruns/、dataset.json、golden_shipped.json)不入库:体量大、且随各源返回内容
天然漂移,按上面的步骤几分钟就能重建。

## 四点五、也能反过来测「已经在引擎里的项该不该留」(2026-09-10 加)

`dims` 那组评的是"还没进引擎的维度值不值得加";`inEngine` 那组反过来,delta 取负号就是把
已入引擎的项拿掉。报告里单独一格 `in_engine_ablation`,别跟上面那组混着读。

同日一起加的两格,都是被"全维度 improve=0 regress=0"这个结果逼出来的:

- **`yardstick_liveness`**:三把量尺在**本轮样本**上的取值分布。全 neutral 有两种完全
  不同的解释——「这个维度确实不改变对错」和「量尺在这批样本上根本判不出对错」,不把
  分布打出来就分不开,而后者会让整份报告变成一句空话。行数项那轮实测:799 条候选里
  内容判"错"的只有 6 条、时长非 fit 的 59 条 —— 量尺是活的,但很薄,尾部风险测不到,
  这句话必须写进结论。
- **`lines_flip_pairs`**:翻盘的那两条候选**到底差在哪**(原始行数 / 正文行数 / 归一化
  正文字符数 / 两份正文的 3-gram Jaccard)。right/wrong/fit/mismatch 是粗档,全 right→right
  时答不出"是不是其实一份更完整";量到字符层面才看得出行数项那 +7 行只换来 +15 个字符。

## 四点六、⚠️ 取样会写用户真实的五份缓存,必须隔离

`collector search-lyrics` 在 `load*` 里顺手把**落盘路径**也设上了,一共五份
(`searchcli.go:76/81/85/88/92`):`artist-alias` / `artist-primary` / `apple-catalog` /
`apple-storefront-artist` / `qq-artist-name`。保存走 `<path>.tmp` + rename,而 **tmp 名
固定、不带 pid**(`musicbrainz.go:88/472` 等)。`run_searches.py` 并发 3 再叠上常驻
collector = 四个进程抢同一个 `.tmp`:轻则丢更新(各写各内存里那份完整 map),重则 rename
出半截 JSON。

隔离办法:给采样进程设 `LYRIMUSE_CONFIG_DIR`(`paths.go:17`,**要绝对路径**),目录里铺:

- `lyrimuse-features.json` — **拷贝**。缺了不会全禁用(静默退默认值),但退的是默认集合、
  不是用户当前的「歌词来源」开关,源覆盖面会跟真实配置对不上。
- 上面那五份 — **拷贝**(隔离的正题)。
- `lyrimuse-musixmatch-token.json` — **拷贝**。不给的话每个一次性子进程各自 `token.get`,
  一密集就 401,Musixmatch 在样本里基本等于整体失效,命中率系统性偏低。
- `lyrimuse-enrich-cache.json` — **symlink 就行**(`loadEnrichCacheReadOnly` 刻意不设
  `enrichPath`)。别省掉:不给的话 `learnedSourceArtistAlias` 那一档恒空,打分会变。

另外:采样跟常驻 collector 抢同一份 iTunes 限流额度(2026-09-10 实测被连带回了两次 429、
一次 403,正撞在用户换歌那一秒),**用户在听歌时把并发降到 1**。

## 五、踩过的坑(都真的踩过,别再踩一遍)

1. **delta 必须加在夹底前的原始项和上**再统一 `max(1,·)`。加在已夹底的分上会把引擎
   吸收过的负分退还,系统性高估一切正向维度;
2. **聚类平手要确定序**(靠 Go map 迭代序会导致跨运行结果不同);
3. **YRC 与 LRC 的末尾比较要同类量**(末行 start vs 末行 start)。拿"末词唱完时刻"比
   "末行起点"天然带一行歌词长度的正偏差,会误杀真逐字候选;
4. **本机必须用 `/opt/homebrew/bin/go`**:PATH 里的 go1.21 产出的测试二进制缺 LC_UUID,
   在本机 Darwin 27 上被 dyld 拒载(与代码无关)。

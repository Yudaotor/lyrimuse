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

## 五、踩过的坑(都真的踩过,别再踩一遍)

1. **delta 必须加在夹底前的原始项和上**再统一 `max(1,·)`。加在已夹底的分上会把引擎
   吸收过的负分退还,系统性高估一切正向维度;
2. **聚类平手要确定序**(靠 Go map 迭代序会导致跨运行结果不同);
3. **YRC 与 LRC 的末尾比较要同类量**(末行 start vs 末行 start)。拿"末词唱完时刻"比
   "末行起点"天然带一行歌词长度的正偏差,会误杀真逐字候选;
4. **本机必须用 `/opt/homebrew/bin/go`**:PATH 里的 go1.21 产出的测试二进制缺 LC_UUID,
   在本机 Darwin 27 上被 dyld 拒载(与代码无关)。

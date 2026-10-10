# 歌曲实体回归案例(song entity cases)

本机真实的几组写法,和人判过的「哪几条是同一份录音」——每类至少一组,守住「改了实体规则之后,这一类还分得对」。
规格见 `docs/features/18-song-entity.md`(决策 7)。跑法就是普通 `go test`:

```sh
GOTOOLCHAIN=go1.24.4 go test -run 'TestSongEntityGolden' -v .
```

| 测试 | 守什么 |
|---|---|
| `TestSongEntityGolden` | 每个案例:实体划分跟 `truth` 一样(硬断言);共享组、全部证据边、否决、被闸挡下的边数跟 `expect` 一样(快照) |
| `TestSongEntityGoldenCategoryCoverage` | `songGoldenCategories` 每一类至少一个案例,且案例确实体现它(按建表结果判,不按标签) |
| `TestSongEntityGoldenFixturesWellFormed` | 至少两条写法、`truth` 恰好覆盖全部写法、条目只带白名单字段、正文是置乱过的 |
| `TestSongEntityGoldenEntryKeys` | 建表读的条目字段(按 `songentityvariant.go` 源码认)都在白名单 `songGoldenEntryKeys` 里 |

跑的是生产同一份 `songVariantOf` + `buildSongEntities`。

## 改了实体规则之后

1. 先跑上面那条命令。`[划分]` 是哪组并错、拆错了:`truth` 不会被自动改写,规则改错了就改规则;真是 `truth` 判错了,
   手改那个文件的 `truth`,在提交说明里写清楚。
2. `[快照]` 是边、否决、共享组、闸的计数变了。有意的改动就重写,再看 git diff 逐个确认:

   ```sh
   SONG_ENTITY_GOLDEN_UPDATE=1 GOTOOLCHAIN=go1.24.4 go test -run 'TestSongEntityGolden$' .
   ```

## 加一组

写一份清单(放仓库外),每项是 `id`、`category`(`songGoldenCategories` 的键)、`note`(为什么挑这组、人是怎么判的)、
`truth`(同一份录音分组,要列全涉及的实体的每一条写法;`song-entities -entity <关键字>` 能列出来):

```sh
SONG_ENTITY_GOLDEN_CAPTURE=<清单.json> GOTOOLCHAIN=go1.24.4 go test -tags devtools -run 'TestSongEntityGoldenCapture$' -v .
```

采集器只读本机缓存,写入前过四道闸,任一不过就不写(见 `songentitygolden_capture_test.go` 头注):`truth` 恰好是那几个实体的
全部写法;只拿这几条建表跟全库建表一样、跟 `truth` 一样;置乱前后建表结果逐项相同;写出的文件读回来重跑不变、体现它的类别。
只挑规则判对了的组:判错的(漏合、并错)写进标注集和 18 章,不进这里。

## 为什么正文是乱码

跟 `testdata/lyricsgolden` 一样,歌词正文不能明文进仓库。同一个案例里所有写法的正文、逐字共用一套保形置乱(字符双射,
时间戳、标点、署名行结构原样),所以用词重合、三元组、时间轴这些比对结果不变;采集器把「置乱前后建表结果相同」当作硬闸。

## 哪些否决没有案例

版本、删减版、无人声、歌词用词、歌词时间轴这几种否决,本机数据里没有人判得清的组(删减版那几组里不带标记的写法分不出是哪一版;
用词否决的四对其实是同一首),由 `songentity_test.go`、`songentityevidence_test.go` 的单测守。

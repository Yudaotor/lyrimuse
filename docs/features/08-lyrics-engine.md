# 08. 歌词同步引擎(App 侧消费链)
> 最后核对:2026-08-25 · 基线:bd02c85+工作树

## 定位

App 侧「从磁盘缓存到屏幕」的整条歌词处理链:collector(独立 Go 进程)把解析好的歌词写进磁盘缓存,本章讲 Swift App 怎么把它读出来、解析、过滤、按播放位置定位到当前行,并以 20Hz 发布给各个展示面。它是所有歌词展示面(悬浮窗、灵动岛、歌词窗口、菜单栏)共享的唯一数据管线。

## 入口与展示面

这条链本身没有直接的用户入口,用户通过它的**消费面**接触它:

- **桌面悬浮歌词**(`LyricsOverlayView`):当前行 + 可选的下一句预览、逐字填色、罗马音/译文。
- **灵动岛**(`NotchLyricsView`):当前行(逐字或整行)。
- **歌词窗口**(`LyricsWindowView`):整份歌词列表(`allLines`)+ 当前行高亮定位(`currentLineIndex`),点击某行可 seek。
- **菜单栏歌词**(`MenuBarStatusItem`):当前行纯文本(`plainText`),跑马灯用 `currentLineDwellSeconds` 配速。
- **设置页**「歌词 → 显示」分组:卡拉OK效果、中文繁简、罗马音语言开关、双行显示、时间轴偏移(下拉框选作用于哪个播放器 + Stepper)。
- **菜单栏状态菜单**「歌词时间轴」子菜单:单曲提前/延后/重置;全局快捷键也能触发同一组动作(`GlobalHotkeys`)。
- **歌词管理窗口**:偏移输入框直接写 `LyricsOffsetStore`,保存/删除歌词后强制让引擎重读。

## 行为规格

### 整条链的形状

```
~/.config/lyrimuse/lyrimuse-enrich-cache.json   (collector 写,App 只读)
        │ EnrichCacheReader.lookup (mtime 缓存 + key 归一化 + 宽松匹配)
        ▼
LocalPlaybackSource.reloadCurrentLyrics()        (换歌 / 缓存 mtime 变 / 设置变时)
        │ 简繁转换 → LyricsSyncEngine.load()
        ▼
LyricsSyncEngine  (LRC/YRC 解析 → 署名行过滤 → 逐字/整行选路 → 对唱分栏)
        │ 20Hz fastTick: activeLine / upcomingLineText / activeLineIndex
        ▼
LocalPlaybackSource 的 @Published (currentLine / nextLineText / currentLineIndex / allLines …)
        │ Combine 逐条转发
        ▼
PlaybackCoordinator (UI 层唯一入口) → 各展示面
```

逐字**填色进度**不走这条 20Hz 管线:`SyncedLyricWord` 只带真实起止时间戳(startMs/durationMs),View 层用 TimelineView 按渲染帧频从 `anchor`(`ProgressAnchor`,进度外推锚点)直接现算 fillFraction。20Hz tick 只负责判断「当前是哪一行」。

### 缓存直读(EnrichCacheReader)

- 缓存文件是 collector 维护的 JSON 字典,key 为「歌手|歌名|专辑」(两侧各自归一化,必须逐字节一致)。value 里有 `lyrics`(LRC 整行)、`lyrics_tr`(译文 LRC)、`lyrics_roma`(罗马音 LRC)、`lyrics_yrc`(逐字)、`instrumental`(纯音乐确证)、`ts`(解析完成时刻)。
- **mtime 缓存**:文件设计上永久不清理(几百条、几 MB),`loadEntries()` 按文件 mtime 缓存解析结果——文件没变就直接复用,只有 collector 真写过新内容才重新读+解析。`fileModificationDate` 单独暴露给 `LocalPlaybackSource`,让它每轮快照(约 2s)用一次 stat 判断「collector 是不是又写过了」。
- **key 归一化**:查询前必须过 `EnrichCacheKeys.normalizedKey`(cleanTag 折空白/删零宽字符 + normalizedTitle 剥歌名结尾的译名括号、版本词保留)。跟 collector 的 `enrichkey.go` 逐字节对应,selftest 用同一组用例锁死。不归一化的后果是「悬浮窗整首歌查不到词」而不是显示旧内容。
- **宽松匹配兜底**:精确 key miss 时,按「忽略空格/大小写/繁简」(`EnrichCacheKeys.looseKey`,繁简用 CFStringTransform)再扫一遍;多个候选取 key 字典序最小的那条(Dictionary 遍历顺序不稳定,不能撞见谁用谁)。繁简折叠**刻意只放在这层兜底、绝不进 key 构造**:Go 侧 OpenCC 和 Swift 侧 ICU 对部分字取舍不同,折进 key 就是整首没词,放兜底层折不对只是退化成多一条重复条目。
- **resolved 语义**:`ts > 0` 代表「联网解析完整跑完一轮」——找不到歌词也会写一条只有 ts 的记录。不能用「key 存在」当判据:外围字段补全路径(封面等)也写这个 key 但不动 ts。
- **封面索引**:`coverURL(artist:title:album:)` 三级查找(精确 → 宽松 → 忽略专辑的 `coverByArtistTitle()` 索引,索引跟 mtime 缓存同寿命),给「最近播放」列表和 `PlaybackCoordinator` 的高清封面替代当 Last.fm 之外的兜底;`nativeSizedCoverURL` 只对网易云图床剥 `param=` 尺寸参数拿原图。

### 解析(LRCParser / YRCParser)

- **LRCParser**:一行可带多个时间戳(副歌重复),每个时间戳各生成一条 `LyricLine`;去掉所有 `[...]` 后正文为空的行(纯标签/元信息)跳过;小数位 1~3 位按「右补零取前 3 位」归一化;输出按 timeMs 排序。
- **YRCParser**:行头 `[行始ms,行长ms]`,词形如 `(词始ms,词长ms,0)文字`。三个防御,全是真实数据打出来的:① 词文字里的字面 `(`(如 "(oh)")用负向前瞻区分「真时间戳元组」和「歌词内容」;② 缺第三段 flag 的畸形两段式元组 `(数字,数字)` 在跑词正则前整个切掉,否则裸数字会被显示给用户;③ 没有任何非空词的行整行丢弃。
- **CRLF 坑(两个解析器共有)**:Swift 把 `\r\n` 当**一个**扩展字形簇,`split(separator:"\n")` 按 Character 比较切不开,整份文本变成「一行」——YRC 侧解析结果为空,LRC 侧更糟:每个时间戳都生成一条、text 全是整首歌拼在一起的巨串,表现是「整个桌面都是歌词」。两个 parse 入口都先把 `\r\n`/`\r` 归一化成 `\n` 再切。

### 加载与选路(LyricsSyncEngine.load)

1. LRC 和 YRC **各自**解析并各自过署名行过滤(不是「有 YRC 就一定用 YRC」)。
2. **覆盖率判据**:`usingWords = 过滤后逐字非空 && (整行为空 || 逐字行数*2 >= 整行行数)`。逐字行数不到整行的一半就认为这份 YRC 是退化的(真实案例:某歌 YRC 只有 10 行、9 行是署名,过滤后剩 1 行,整首歌卡在那一行不动),退回整行模式。LRC 本身为空时没得选,仍用逐字。
3. **对唱标记剥离**(2026-08-23 重写,见 `LyricDuet`):
   - **先认身份、再过滤署名、最后剥离**,顺序不能反 —— 「每句都带标记」的对唱歌天然满足署名过滤"命中 ≥3 行且过半"的闸门,先过滤就是整首被删空。`LyricDuet.speakers(in:)` 的结果作为 `speakerExemptions` 喂给 `strippingCreditLines`,在所有规则**最前面**放行。
   - **两条路径分别认**:整行走 `LyricDuet.plan`、逐字走 `LyricDuet.planWords`。逐字侧判定必须在**整行词拼起来**的文本上做 —— 真实 YRC 里标记的切分形态不固定(`男：周` / `男`+`：` / `周`+`杰`+`伦`+`：`),只看第一个词会漏掉绝大多数(重写前 13 首带标记的歌里 11 首因此归零)。剥离按**字符数**从词序列前端剥,剥到一半的词改文本、保留时间戳。
   - **独占一行的标记整行丢掉**(`dropped`):它带着自己的时间戳,不丢就是屏幕上凭空多出一句词。⚠️ 过滤 `sides` 只能 filter+map,不能 compactMap —— 元素本身是 `Side?`,nil 是正常值,compactMap 会把它们连同被丢的行一起摘掉、整条归属错位一格。
   - 左右按标记**首次出现顺序**分(先出现靠左),合唱类居中且**不参与交替状态机**(否则「男-合-女」会把侧算反);同一位歌手的不同写法(男/男声/男合)先归并成同一身份再排席位。第一个标记之前的行 side 为 nil(= 没有对唱信息,各视图自己兜底:歌词窗口 `?? .leading`、悬浮窗 `?? .center`)。
4. `romaLines`/`trLines` 独立解析,**不过署名行过滤、不做简繁转换**(罗马音是拉丁字母;译文的转换在送进来之前已由 LocalPlaybackSource 做了)。
5. 整首粒度判一次 `songLooksJapanese` 和 `songScript`(japanese/korean/chinese/other,给按语言的罗马音开关用);解析酷狗 `[kana:]` 假名标注(对不齐就整份弃用);清空罗马音/词组两个按行缓存。
   ⚠️ 判定样本是**过滤掉署名行之后的正文**(`filteredBase`/`candidateWords`),不是原始 lyrics/lyricsYRC —— 2026-08-20 改。原来刻意把署名行算进去(理由写的是「一首歌出现过假名就确证日文」),而**中文翻唱的署名行带日文原作者名是常态**:实测泠鸢yousa《神的随波逐流》整首歌唯一的假名就是「词：れるりり」「曲：れるりり」两行,正文全中文,却被判成日文 —— 于是用户关着的「中文」罗马音开关根本没机会说话(闸看的是整首歌的语言),每行中文都被标上东西:日语分词器给得出读音的出日文读音(词典外的字原样留着,表现为「有些字有有些字没有」),给不出的退到 ICU 音译出拼音,同一首歌两种形态混着出。署名行说的是「谁写的」,本来就不是「这首歌唱的是什么语言」的证据;真日文歌正文假名遍地,判定结果不变。两份正文都空时退回原始字段。selftest 用真实歌词片段钉了四条:署名行被过滤、中文关着时一行罗马音都没有、用户主动开中文时照样给、真日文歌不受误伤。
   已知边界(刻意接受):**中日双语歌**的中文行仍会跟着整首的日文判定走 —— 修它要把「按行判语言」和「纯汉字的日文行必须继承整首判定」两件事一起解决,不是这次的范围。

### 署名行过滤(creditRoleWords 规则族)

目标:作词/作曲/制作人这类职员表行在**喂进引擎之前**剔除,让「还没到第一句真歌词」判定正确(占位符 ♪ + 双行预览提前露出第一句)。规则分逐行生效和整份闸门两类:

**逐行生效**(误杀面小):
- `creditLinePattern` 关键词表:精确角色名(两字全称/单字缩写/`by:` 写法),允许角色词**连写**(「词曲：」)和夹连接词(「制作和编曲:」「所有乐器和编程:」)。
- `matchesRoleWordCredit` 双字角色词包含判定:冒号前 1~10 个纯汉字(先剔掉「/、&」等标签分隔符再算)、且**包含**任一双字角色词(「数字编辑」含「编辑」)→ 删。刻意只收双字不收单字:单字「曲」会误杀对唱标签「曲婉婷:」。「合唱」刻意不收(对唱分声部标记后面是真歌词)。
- `matchesEnglishCredit` 无冒号英文署名:整行以角色词开头 + 紧跟 by/at + 后面有内容(「Mixed by X at Y」)。
- `matchesLatinCreditPattern` 拉丁标签:全角冒号(「Guitar:秋山浩徳」——英文歌词几乎不会出现全角冒号);半角冒号只在冒号后跟中日文时才认(不误杀 "Verse 1: ...")。
- `looksLikeHeaderLine` 抬头行:「曲名 - 歌手」只在**第一行**认,要求同时含曲名和歌手名(归一化 + 剥括号段再比,应对 "(Remastered)" 后缀)。

**整份闸门**(误杀一行 = 静默吞一句真歌词,不能逐行放开):
- `matchesNameListCreditShape`「标签 + 冒号 + 名字串」形状(2026-08-20 第十轮加,整份 ≥2 行才启用):标签侧 1~10 纯汉字(允许分隔符,说话人标签豁免);右侧总长 ≤14、按 `/、&,` 切成 1~4 段、每段 2~8 个汉字/拉丁字母,且**一个 `nonNameChars` 都不含**(的了是不我你他她在也都就很没…这类"人名里不可能出现"的虚词)。
  起因:用户报赵雷《成都》头部 13 行职员表漏了 4 行(`钢琴：柳森`/`箱琴：赵雷/喜子`/`笛子：祝子`/`童声：朵朵/天天`)——这几个乐器词不在 `creditRoleWords` 里,而结构化规则被"过半"闸拦着(13 行署名 vs 三十多行正文)。
  **精度全部来自右侧那条**:这也是它跟本文件末尾那次【已撤销】的"按位置扩展署名块"最本质的区别——那次放宽的是位置、形状照旧只看"短汉字标签 + 冒号",于是「他说：我不走」当场被吃掉;这次收紧右侧,「我不走」含「我」「不」、「算了」含「了」,一个都过不去,而「柳森」「赵雷/喜子」「亚洲爱乐国际乐团」全是干净的名字。
  同一轮还往 `creditRoleWords` 补了乐器类双字词(钢琴/箱琴/笛子/童声/口琴/二胡…),专门兜"整首只有一行署名"、够不到 ≥2 门槛的场合。selftest 钉了 17 条(6 正 8 反 + 《成都》真实头部端到端)。
- `genericHanCreditLinePattern` 结构化规则(1~8 汉字 + 冒号 + 非空内容)只在 `shouldApplyStructuralCreditFilter` 通过时启用:命中 ≥3 行**且**过半(治「网易云给纯音乐返回整份职员表」),两个条件缺一不可。
- `speakerLabels` 说话人豁免:「男/女/合/旁白…」形状 100% 命中结构正则但后面是真歌词,豁免名单是必须的——每句都带标签的对唱歌天然满足「过半」闸门。
- **永不删空兜底**:`strippingCreditLines` 里全部行都被判成署名时一行都不删(宁可漏治,不可整片空白)。跟 collector 侧「整份拒收」不同:那边拒了还有别的源顶上,这边删空就真什么都没有了。
- **全库语料回归**(2026-08-20 加):`creditLineDropDecisions` 是给 selftest 开的测试接缝(整份进、每行出)——整份闸门是这套规则的一半,只测单行匹配函数测不到。selftest 里固化了 60+ 条样本(34 条必须留下 / 26 条必须删掉 + 抬头行/永不删空),全部取自用户本机缓存 935 首 47626 行正文的全量跑测结果,按家族抽样;每条都放在「旁边就是一段能打开双语/名字串两道闸的署名块 + 8 行普通歌词」这种最恶劣但真实的上下文里判。
  ⚠️ 这套语料测试当场抓到一整类真误杀:**拉丁字母的说话人标签**(`Rain：给我大声地说我爱你` ×12、`S:只会让我不小心`、`A: one..two..three`、`SL：`、`N.Chen：`、`Rap:`)被 `matchesLatinCreditPattern` 整行删掉,共 29 行。那条规则原来只看「拉丁标签 + 冒号」的形状、完全不看冒号右边(它 2026-08-10 上线时的实测样本只有 537 行)。修法是加一道否决 `latinCreditRestLooksLikeSentence`:右边含中文虚词、或含谚文且带两个以上空格、或以句末标点收尾 → 判成句子、放过。改完全库回归:被救回 16 类 / 29 行,**新增误删 0 行**。做过变异测试(把这道闸拆掉 → 7 条断言立刻点名报错),证明它不是空转。
- **第十一轮(2026-08-20,同日):按语料统计把漏网收干净 + 补护栏**。上一轮的语料同时量出了反方向的 56 行漏网署名,这一轮按家族收:①拉丁标签正则的标签上限 28→40(`Additional Vocal Production by：` 标签本身 30 字),半角那条允许 CJK 之前隔着空格/数字(`P - Line: 2016 北京…` 的第一个词是年份);②`℗/©`(`P - Line`/`C - Line`)收进关键词表(跟 OP/SP 同类,歌词不会以这种前缀开头);③`matchesRoleWordCredit` 允许标签里混拉丁字母/型号/括号、只看**汉字那部分**是否含角色词(`Protools编辑：`、`键盘乐器 DX7 and synths：`),但标签上限仍是 10、纯拉丁标签仍归 latin 规则(两条既有断言守着分工);④名字串形状的长度上限按书写系统分档(纯汉字段 2~8 字、含拉丁的段放到 30 字、右侧总长 60、最多 6 段),英文人名/团体名才进得来;⑤句子否决补英文停用词 `nonNameWordsLatin`(刻意不收 the/and/of/a/by——真实署名里到处是它们),分词按**空白**切并剥掉词首尾标点(按「所有非字母数字」切会从 `(G)I-DLE` 切出孤立的 `i`,把真署名当句子放过)。
  ⚠️ **两条护栏都是语料现场抓出来的,不是想出来的**:(a) 补英文停用词之前,`Rain：Baby I love you so much` 这条真歌词已经在被删;(b) 放宽英文名长度之后,`王：Hey hey ho ho`/`靖：All yours baby` 立刻被当成署名删掉 —— 因此名字串规则加了「标签至少两个汉字」这道闸(单字标签是说话人标签的地盘;单字角色词早就在关键词表里逐行生效),它顺带救回**第十轮就已经在吃**的 9 类真歌词(`方：开个玩笑`/`王：Oh yeah`/`华：喔 喔`/`张：回到拉萨`…)。
  全库最终对照(两轮都在的 935 首):新增被删 **21 类全是真署名**(含从没枚举过的「巴松管」「英国号」「Double Bass/鼓录音室」—— 免词表规则的收益),新增被留 **9 类全是真歌词**。语料样本表随之扩到 84 条断言。

### 歌词自带的 `[offset:]`(2026-08-22 加)

LRC 格式标准里的 `[offset:±毫秒]` = 「这份歌词的全部时间戳整体偏移多少」——打轴的人发现自己整份早了/晚了就写一个 offset,而不是逐行改几百个时间戳。在此之前 **全链路无人消费**:`LRCParser.parse` 把它当元信息行整个跳过(去掉 `[...]` 后正文为空),于是歌词源明确告诉了我们要偏多少,而我们没听,用户只能自己去「歌词时间轴」手动补一个校正值——那个值还绑内容指纹,重搜换一份歌词就作废。

- **不是单个源的特性,所以放在通用解析层**。本机 114 条缓存实测(2026-08-22):酷狗 50 条里 **30 条**带这个标签(其中 2 条非零:242ms / 600ms),QQ 12 条**全部**带(恰好都是 0),网易云 45 条和 Musixmatch 一条都不带,lrclib 只有 1 条样本不足为据(而它是社区上传的纯 LRC,格式上最有可能带)。**只对酷狗特判是错的**。
- **符号跟 `offsetMs` 同号:正数 = 歌词整体提前显示**。规范原文是 "+ shifts the lyrics earlier",换算过来 `显示时刻 = 时间戳 − offset`;而引擎这边是「查询位置 = 播放位置 + offsetMs」再扫 `timeMs <= 查询位置`,两者等价,可以直接相加、不用取反。
- **`lrcOffsetMs` 跟 `offsetMs` 分开存**,`effectiveOffsetMs = offsetMs + lrcOffsetMs` 才是定位用的总偏移(五个查询入口全部改用它)。分开的理由:那个是用户手调的三层合成结果,这个是歌词内容的属性;混在一起的话换一份歌词时旧的 LRC offset 会残留在用户那层,而且设置页显示的数字会莫名多出几百毫秒。分开还有个实际好处——**万一某个源的符号约定跟规范相反,用户用单曲微调抵消即可**,不需要我们去猜哪个源该取反。
- **量级闸 `maxOffsetMs = 10_000`**:超出一律当 0。见过畸形数据把整份歌词推到几十秒开外,那种"修正"比不修正糟得多。多个 offset 标签**取第一个**(文件头部才是元信息区)。
- **整行为空时从 YRC 取**:酷狗那两首非零的实测里 `.lrc` 和 `.yrc` 两份头部带的是同一个值(KRC 母版转出来的两种形态),所以逐字模式同样吃它。
- ⚠️ **`currentLyricsOffsetMs` 必须含这一层**(`applyOffsets()` 里 `effective + syncEngine.lrcOffsetMs`):它的唯一用途是"把歌词时间轴换算到播放位置",而歌词窗口点某一行反算 seek 目标用的就是 `行时间 − currentLyricsOffsetMs`,漏掉这层的话带非零 offset 的歌点行会跳到隔壁行。而用户可见的那两个数(设置页的基准、菜单里的单曲值)**不**含它 —— LRC offset 不是用户调出来的,不该出现在"你调了多少"里。
- ⚠️ **时序**:`applyOffsets()` 读 `syncEngine.lrcOffsetMs`,所以它必须排在 `syncEngine.load()` **之后**(`reloadCurrentLyrics` 里本来就是这个顺序);反过来会套用上一首歌的 offset。`load()` 的指纹早退不影响 —— 早退时内容没变,这一层的值本来就该保持。
- selftest 覆盖 19 条(解析的各种形态 + 量级闸 + 两层相加 + 换歌归零 + 从 YRC 取)。

### 查询接口(按播放位置定位)

四个入口都在查询位置上先加 `offsetMs`(时间轴校正,见下节),然后线性扫「timeMs <= 位置」的最后一行:

- `activeLine(atMs:)` → `SyncedLyricLine`:逐字模式给 `words`(+可选 `wordGroups`)、整行模式给 `mainText`,两者只有一个非空(`plainText` 按此取值);`translation` 用 `nearestText(trLines, 行时间戳, 容差700ms)` 最近邻贴行,超容差该行就没有译文;`romanization` 同理(见下节);`side` 为对唱分栏。位置还没到第一句时返回 nil。
- `upcomingLineText(afterMs:)`:下一行纯文本(双行预览用)。**故意**不要求当前行存在——还没到第一句时(idx=-1)直接把第一句真歌词当预览提前露出(署名行过滤上线后这个窗口更常见)。
- `activeLineIndex(atMs:)`:当前行下标(歌词窗口滚动定位用)。故意不用「拿 activeLine 内容去 allLines 找」——副歌重复句内容相同,必须按时间戳直接扫下标。
- `allLines(idPrefix:)`:整首歌全部行一次性构造(歌词窗口用),每行同样贴罗马音/译文。id = `"\(idPrefix)#\(行号)"`,idPrefix 由调用方传曲目标识(实际传 `currentOffsetKey`)——保证换歌后 id 集合整体不同,SwiftUI ForEach 做干净整体替换而不是逐行「变形」旧内容(否则换歌瞬间串行/闪烁)。

### 罗马音(Romanizer)

- **优先级**:服务端 `lyrics_roma` 字段(700ms 最近邻)> 客户端现算兜底。兜底只在 `romaLines` **整体为空**时启用——不在「这行没匹配上、别的行有」的局部空档里现算,避免混搭观感。
- **按语言开关**(`RomanizationScripts`,设置页三个复选框):按整首歌的 `songScript` 管辖,japanese/korean/chinese 三档可独立开关,默认 `[.japanese, .korean]`(= 改成可配置之前的实际观感;中文默认关,否则每首中文歌凭空多一行拼音)。`.other`(拉丁/泰文/西里尔…)不受管辖,始终允许。这道闸在**服务端字段之前**——用户关掉的意思是「别给我看」,不是「别现算」。
- **日文必须走形态分析**(CFStringTokenizer + ja_JP locale),不能用 ICU Any-Latin:汉字是中日共用文字,Any-Latin 一律按普通话读成拼音。判据 `songLooksJapanese` 按整首传入。非日文非中文文字 Any-Latin 本来就无歧义,继续用;输出等于输入(本来就是拉丁字母)时返回 nil,不展示一行重复文字。
- **助词修正**:单独成 token 的 は/へ/を 读 wa/e/o;こんにちは 等整词固定语单列。促音「っ」的字面 "~tsu" 按赫本式双写后一个辅音归并(`mergeSokuon`)。
- **假名标注优先**:酷狗 `[kana:]` 标注(`KanaAnnotation`)给出多音词的实际读音(「明日」到底念 asu 还是 ashita),优先于分词器;按行文本索引,对不齐整份弃用退回形态分析(半对半错比不标更糟)。逐音节时间戳目前只解析不使用。
- **逐词分组**(`wordGroups` / `buildWordGroups`):Apple Music 式「罗马音标在对应内容正下方」。整行一次性分词再按 UTF-16 范围对回逐字词(日文读音吃上下文,不能逐词单独求);分词边界跟歌词源逐字切分不对齐时把跨边界的词并成一组,一组共享一段罗马音,组的起止时间给下面那行罗马音算填色。只对日文产出;一组罗马音都配不上时返回 nil,视图退回整行罗马音。受同一道语言开关管辖。消费方是悬浮窗和歌词窗口(灵动岛/菜单栏只用纯文本)。
- **三个按行缓存**:`romanizerFallbackCache`(20Hz tick 每次都会重新构造当前行,不缓存的话纯英文歌每秒 20 次重跑 ICU 音译,实测拖慢到「本地歌词肉眼可见比网页慢」)、`wordGroupCache`(分词是纯 CPU 活;⚠️ key 是「首词时间戳+行文本」不是裸文本——词组内嵌**绝对**时间戳,只按文本缓存会让副歌重复句借用第一次出现的时间轴,2026-08-20 对抗审查抓出的预存在 bug,selftest 钉住)和 `segmentsCache`(2026-08-20:整行读音兜底与逐词分组共用**同一次** CFStringTokenizer 分词——原来两条管线对同一行各分一遍,日文歌 allLines 构建的分词次数直接翻倍;整行读音由 `Romanizer.readingFromSegments` 从片段派生,与旧 `japaneseReading` 管线逐位等价,selftest 有一致性断言;两个消费方的启用门不同——逐词分组要求行内有假名、整行读音只要有汉字——所以缓存在两道门之前、按纯文本 key,时间无关可安全共享)。换歌词内容时清空(纯内存卫生,不清也不会算错)。
- **按行下标记忆化**(2026-08-19):`activeLine`/`upcomingLineText` 缓存上一次构建的整份结果,下标没变直接返回同一实例——20Hz 调用约 99% 命中同一行,原来每 tick 都白做词数组 map、两次整行拼接和两次最近邻扫描,构建完即被调用方 `!=` 丢弃;返回同一实例还让深比较走存储同一性快路径。定位扫描统一走 `activeIndexCorrected`(数组按 timeMs 升序,越过 posMs 即 break;2026-08-20 再加 `lastScanIdx` **单调窗口记忆化**——播放位置单调推进,~99% 的 tick 落在上次命中行的时间窗内,O(1) 验证即返回,seek/换行/offset 变化时验证失败自动回退全扫)。缓存在 `load()` 失效(⚠️ 忘了失效会把上一首歌的行返回出去,selftest 钉住);offsetMs 只影响下标不影响某行内容,偏移变化天然安全。
- **tickQuery 打包查询**(2026-08-20):fastTick 要的当前行/下一句/行下标/间奏下标是同一个 posMs 的同一次定位,原来四个入口各自独立扫一遍——`tickQuery(atMs:)` 下标只算一次、四个值一起返回(与四个独立入口逐位一致,selftest 双向对拍含倒退 seek),调用方从四行收敛成一次调用。四个独立入口保留(其它调用方仍在用)。
- **load() 入参指纹早退**(2026-08-20):8 个入参与上次完全一致时直接 return false,整段解析/过滤跳过、三个按行缓存和下标缓存**保住**(输入相等 ⇒ 派生状态必然相等)。这是对付「enrich 缓存是全库单文件,collector 给别的歌写盘也 bump mtime」的第二道防线,第一道在调用点(见下面重读时机)。

### 简繁转换(ChineseVariant)

- 三档:不转换/简体/繁体。转换发生在 `reloadCurrentLyrics()` **送进引擎之前**,正文、译文、逐字数据都转(YRC 整串转安全——时间戳是数字),罗马音不转;缓存原文一个字节不动,切回无损。
- **日文歌一律原样返回**:判据「有假名就是日文」——日文新字体(学/国)被简繁转换改掉不是转换,是写坏。用 ICU `Simplified-Traditional`,非无脑逐字(头发→頭髮 正确)。本机 1487 条缓存实测:42 首被这道守卫拦下,**全部是真日文歌**(Sou / 米津玄師 / タイナカ彩智 …),没有中文歌被误拦。
- **转简体时必须再补一层异体字规范化**(`HanVariants`,2026-08-22 用户报「明明开了简体,歌词里还是看到繁体」):ICU 只管**繁简**,不管**异体字**。实例《开不了口 (Live)》——ICU 把那首歌 37 种字符全转对了(沒→没、煩→烦、開→开、讓→让…),**只剩「妳」没动,而它出现 21 次**,整屏都是,看着就是"压根没转"。
  - 根因不是 ICU 有 bug:「妳」不是「你」的繁体,是大陆《第一批异体字整理表》淘汰、港台仍在用的**异体字**,不在繁简转换的范畴里。**换 OpenCC 也一样** —— collector 用的 gocc,它的 `TSCharacters` / `TWVariantsRev` / `HKVariantsRev` 三张字典全库 grep 过,「妳」「祂」「牠」**零条目**。这一层只能项目自己维护。
  - 现表 6 字(本机缓存实测词频):妳→你 149 次 / 祂→他 50 / 濛→蒙 28 / 牠→它 2 / 痲→麻 1 / 痺→痹 2,覆盖 21 首曲目、230 处字符。收录标准见 `HanVariants` 的注释:① ICU 确实不转它 ② 大陆规范有明确取代字 ③ 歌词语境无歧义。第三条否掉了「祇」(神祇 vs 只)、「乾」(乾坤,ICU 已按上下文正确保留)和粤语字「嘅咁哋冇」(不是异体字,转了才错)。
  - **只在转简体方向生效,绝不反推**:简体只有「你」,转繁体时无从判断该写「你」还是「妳」——那要猜被称呼者的性别。
  - ⚠️ 排查这类问题时**别拿 ICU 去检查 ICU 自己的输出**:第一版扫描用的判据是「某字单独能转、整串却没转」,那只能发现 ICU 的上下文漏字(全库仅 3 个「著」),发现不了 ICU 压根不认的字,于是漏掉了正主。有效的过滤器是「`Hant-Hans(c)==c` 且 `Hans-Hant(c)==c`」——ICU 双向都不动的"通用字",高频的是正常字、低频端才是异体字候选(3742 种汉字缩到 2466 个,妳/祂/牠/痲 全落在里面)。
- **设置项条件显示**:`sawChineseLyrics`(LocalPlaybackSource 上的粘性标记,判据「有汉字且无假名」,只置不清)→ AppDelegate 首次见到时持久化为 `AppSettings.hasSeenChineseLyrics`;设置页在「系统读中文 || 见过中文歌词 || 已不是默认值」时才露出这一项。最后半边是硬要求:开关正在起作用时绝不能消失。

### 时间轴偏移:基准(全部 / 按播放器,二选一)+ 单曲微调(LyricsOffsetStore)

- **全局偏移**(`globalOffsetMs`):设备侧固定延迟(蓝牙耳机等),对所有歌生效,裸 Int 存 UserDefaults。设置页那一行选「全部播放器」时改的就是它(Stepper ±5s、步长固定 0.05s,刻意不复用快捷键页的「调整步长」)。存储层**没有**「全部」这个哨兵 —— 那个下拉框只是作用域选择器,在既有两层之间切,不是第三份存储。
- **按播放器偏移**(`playerOffsets`,2026-08-21 按用户要求加):`bundleID → 毫秒` 字典,存 `np:lyricsOffsetsByPlayerJSON`。设置页那一行的下拉框选中具体播放器时改的是这层。它对症的是**播放器侧**的系统性偏差:浏览器(Arc/Chrome 这类)只在切歌时报一次播放位置、之后 `elapsedTime` 再也不刷新,只能按墙钟外推(`PositionSourceTier.cleanExtrapolated`),进度会系统性偏慢;而 Apple Music 那条路径精确、一点都不该补。这类偏差**换首歌照旧、换个播放器就没了**,正好落在播放器这个维度上。
  - **维度只能是 bundleID,不能是 `PlaybackPlayer` 枚举**:功能动机里那个 Arc 压根不在枚举里(枚举只有 Apple Music/QQ/网易云/酷狗/Spotify/自动),它靠 `TrustedPlayers` 那份 features.json 的 bundleID→名字映射进来。改成枚举「更类型安全」就是把浏览器挡在门外。
  - **零值不落盘**(`setPlayerOffset` 归零即删、`loadPlayerOffsets` 再滤一遍):字典里留着的就是「用户真的配过的播放器」,下拉框据此把它们全列出来 —— 哪怕这个 App 已经不在受信任名单里(取消信任/卸载)也必须列出,否则那个非零偏移会变成看不见、改不动的隐形值。
  - **`.auto`(自动识别)不进下拉框**:它的 `bundleIdentifier` 是空串,`setPlayerOffset` 对空串静默 no-op(调了没反应、也没报错);「自动」这层语义由「全部播放器」承担。
  - **换播放器要重算**:`applyOffsets` 的原触发条件只有「换歌 / 没内容 / 缓存变了」,`LocalPlaybackSource.apply()` 里额外记一份 `lastAppliedBundleID`、变了就补算一次。不补的话 `.auto` 档下在两个 App 间切、或两个播放器放同名曲目时(trackKey 只由 歌手\|歌名 决定),新播放器会继续套用**上一个播放器**那一档。
- ~~按播放器补偿(第一版)~~(`np:lyricsPlayerOffsetsJSON`,2026-08-18 加、**2026-08-20 整层移除**):当时以为"Spotify 播放时钟恒比出声超前"是播放器固有属性、加了**代码内部替用户猜**的固定补偿(界面上看不见、也重置不了);后经实测定性为**自然切歌锚点超前**(+0.85s 量级、每首抽签、手动点播没有),已由 `LocalPlaybackSource.naturalAdvanceCorrection` 按曲精确校正(见 02-playback-source.md)——固定补偿对这种偏差不对症(手动点播的歌反被带偏)。**08-21 这版故意换了新键**:复用旧键会把那些为已经修好的 bug 调出来的旧值重新激活、反把歌词拖慢,而旧键的 `removeObject` 清理仍留在 `LyricsOffsetStore.init` 里。两版的分界线是「用户看得见改得动」。
- **单曲微调**:按 `trackKey = "归一化歌手|归一化歌名|内容指纹"` 存(指纹 = lyrics+lyricsYRC 的 SHA256 前 12 hex;前两段走 `EnrichCacheKeys.cleanTag`/`normalizedTitle`,跟 enrich 缓存 key 同一套)——歌词内容换了(重新匹配/手动编辑/换源)key 自然变,旧校正值查不到而不是误用;旧记录不清理(量小)。值为 0 时从字典删除。菜单栏「歌词时间轴」提前/延后按 `lyricsOffsetStepMs`(默认 200ms,快捷键页可调)nudge,「重置」只清单曲不动全局;全局快捷键同一组动作。歌词管理窗口的输入框直接 `setOffset` 绝对值。
- **唯一合成点** `effectiveOffset(forKey:bundleID:) = baseOffsetMs(forBundleID:) + track`,而 `baseOffsetMs` 是**二选一**:这个 bundleID 在 `playerOffsets` 里有值就用它,否则用 `globalOffsetMs`。**两档不相加**(2026-08-21 用户拍板:「不要和那个全部相加,只有要么全部,要么单个」)。零值不落盘,所以"配过"="非零",把某个播放器调回 0 就是撤掉它的单独设置、重新跟随「全部」。
  由 `LocalPlaybackSource.applyOffsets()` 灌进 `syncEngine.offsetMs`(入口:换歌词内容/nudge/reset/改基准/改播放器那档/换播放器,全走这一处,防「两处各加一次 = 双倍校正」)。正数 = 歌词整体提前显示。`bundleID` 省略或为 nil(relay 中继模式没有播放器身份、或还没拿到第一份快照)时用「全部」那档 —— 那是唯一有意义的兜底,**绝不猜一个播放器**(猜错的形态就是把浏览器的补偿套到 Apple Music 上)。selftest 有一条变异测试验证过的断言组钉住"不许退回相加"。
- **两个对外属性**:`currentLyricsOffsetMs` = 实际生效总和(所有「歌词时间轴 ↔ 播放位置」换算用它,如歌词窗口点行 seek 时 `item.timeMs - currentLyricsOffsetMs` 反算);`trackLyricsOffsetMs` = **只属于这首歌那一层**(菜单标题「歌词时间轴(+0.6s)」和「重置」按钮认它——显示总和会出现「点了重置数字却不归零」)。全局与按播放器两层都只进 `currentLyricsOffsetMs`、不进 `trackLyricsOffsetMs`;代价是它们在菜单里完全不可见(跟全局那层的既有现状一致),只在设置页那一行看得到。
- 存储:三份值都在 UserDefaults(`np:lyricsOffsetsByTrackJSON` 与 `np:lyricsOffsetsByPlayerJSON` 存 JSON 字符串方便 `defaults read` 调试;`np:lyricsGlobalOffsetMs` 是裸 Int),**故意不放进** EnrichCacheStore 的「清空全部缓存」波及范围——校正值是用户手动调出来的个人偏好。清它有**单独**的入口:歌词管理工具栏那个「占用」菜单里的「清空全部时间轴校正」(`clearAllTrackOffsets`),只清单曲那一份,「全部」基准和按播放器那份都不受连带(selftest 各有断言钉住)。

### key 前两段必须归一化(2026-08-20 修的真 bug)

- **症状**:播放侧算 `trackKey` 传的是**播放器原始**歌手/歌名,而「歌词管理」传的是缓存 key 拆出来的(已归一化)那两段 —— 同一首歌两个身份。实测这台机器 2483 首里 **111 首(4.5%)**落在这个差异上(歌名结尾带译名括号、`(with X)` 之类):管理页敲的偏移播放时查不到、菜单栏调的值在管理页看不见、「重置」也清不掉。叠加已校准机制之后更别扭:pin 两边都归一化、offset 没有 → 歌被锁住却没享受到校正。
- **修法**:归一化放进 `trackKey` 这个**唯一构造点**,不去改两个调用方(各自记得归一化=迟早又漏一处,而漏掉只在那 4.5% 上出现、极难归因)。归一化幂等,管理页传已归一化的值进来结果不变。版本标记(`(Remastered 2014)`)照旧保留 —— 那是另一个录音。
- **存量搬迁**:`migratedOffsetKeys` 在 store init 里跑,只动前两段、指纹段原样保留,所以**不需要知道歌词内容**、启动时一次搬完(不用等播到那首歌)。撞车(两种拼法+同一指纹)时让本来就是归一化形态的那条赢;段数不对的 key 原样不动。
- **残留的窄边**:归一化刻意**不折大小写**(会污染「歌词管理」列表的显示,见 `EnrichCacheKeys` 注释)。所以缓存条目的歌手/歌名大小写跟播放器此刻报的不一致时(`canonicalEnrichKey` 那条宽松匹配的产物),两边仍会差一个身份。

### 已校准即锁定歌词源(LyricsPinStore,2026-08-20)

- **问题**:单曲校正值的 key 含内容指纹,后台一换歌词内容(rescore/retry)指纹就变、校正值静默作废。实测那台机器 14 条记录里 **13 条已失联**(11 条对应缓存条目已不在、2 条内容换过);而 qq 与 kugou 的分差常年只有 **9 分/约 1330(0.7%)**、时间戳行数完全相同,任何一次重搜都可能翻盘换源。同一首歌隔 10 分钟重抓两次结论相反(netease 限流缺席),即「重解析本身不可复现」。
- **做法**:偏移值非零 → 自动把这首歌钉进 `~/.config/lyrimuse/lyrimuse-lyrics-pins.json`;归零 → 自动解钉。collector 侧 `needsLyricsRescore` / `needsLyricsRetry` 第一道闸就是它(`lyricspins.go`),语义与 `manual_lyrics` 并列。没有任何"记得打开开关"的步骤。
- **两套 key 不能混**:offset key = `歌手|歌名|内容指纹`(播放器原始三段);pin key = `EnrichCacheKeys.normalizedKey`(归一化 `歌手|歌名|专辑`)。pin 认"这首歌",内容指纹恰恰是会变的那一半,拿它当 pin 身份等于"内容一换 pin 也失效",正好把要防的事情放过去。
- **为什么单独一个文件、不塞 enrich 缓存**:collector 持有整份缓存并整份写回,App 往那个 JSON 加字段会被覆盖、想安全就得重启 collector——而偏移是菜单栏按一下就变一次的东西。这份文件几行大小,App 写、collector 按 mtime 重读,**不需要 kickstart**,校准完立刻生效。
- **存量补钉**(`backfillPinIfNeeded`,在 `applyOffsets()` 里调):pin 是"改动时"写的,机制上线前用户已经调好的歌一条 pin 都没有 —— 播放到它、发现"有非零校正值却不在名单里"就补上。刻意不做启动时全量扫:offset key 含内容指纹,离开播放上下文算不出对应的 pinKey。校正值为 0 的绝不补(否则全库进名单、后台升级整个停摆)。
- **刻意不管的**:一次性内容迁移(如 `migrateYRCWhitespaceTokens`)不看 pin——用户要的是"不自动换歌词源",而空白词条清洗修的是实际播放 bug,不属于换源。
- **代价**:pin 住之后这首歌也拿不到后台的歌词升级了(跟 `manual_lyrics` 同样的取舍)。删除条目会连带删 pin(`EnrichCacheStore.delete`);「清空全部缓存」**不**删 pin(两条清理路径刻意分开)。

### 20Hz 发布机制(LocalPlaybackSource)

- **fastTimer** 20Hz(挂 `.common` mode,否则开菜单/拖窗时停摆),只在「有 `anchor`(正在播放)且引擎有内容」时运行;暂停/停止时停掉。锁屏时也停(`setScreenLocked`,只停这条——2s poll 必须继续跑,否则锁屏听歌丢 scrobble)。「在播但没词」(纯音乐/广告/还没解析出来)也停(2026-08-19):每一拍都扫空数组、不可能产出任何 @Published 变化,一首 4 分钟无词歌原来要白唤醒约 5000 次;collector 中途解析出歌词靠 enrich mtime 变化在下一轮 apply(≤2s)拉起,「歌词管理」保存走 `forceReloadLyricsForCurrentTrack` 当场拉起。
- **fastTick()**:从 anchor 外推当前位置 → `tickQuery` 一次打包查询(2026-08-20,原来四个入口各查一遍)→ **值变才赋值**。这些都是 @Published,SwiftUI 不比较新旧值,无条件赋值会让所有订阅视图每秒重算 body 20 次(实测卡顿根因)。绝大多数 tick 还是同一行,赋值实际很少发生。顺带维护 `currentLineFillSettled`(当前行填色是否已定格,悬浮窗 TimelineView 的停表条件,阈值算法在 `KaraokeFill.lineFillSettledMs`;2026-08-20 起阈值按行记忆化——它是行级常量,原来每 tick 对全行词+组重算一遍浮点循环,现在换行才算一次、tick 退化为一次整数比较)。
- **暂停不清行**:anchor 为 nil 但有冻结位置(`pausedPositionMs`)时按冻结位置解一次当前行(`resolveLinesForPausedPosition`,apply 和 fastTick 两个入口共用一处——曾经两处各写一份清空逻辑错开过:暂停下拖进度条行被清掉)。用户按暂停的典型场景正是「这句是什么,我看一下」。真没位置或没内容才清空。
- **重读时机**:`apply()` 在「换歌 || 引擎无内容 || 缓存文件 mtime 变了」时 `reloadCurrentLyrics()`。mtime 那条是为了同一首歌中途 collector 补译文/换更好的歌词能立刻生效;**不要**加「已有译文就不盯」的闸门(译文会被顶替,不只从无到有)。**内容等值闸**(2026-08-20):mtime 是全库单文件的,collector 给**别的歌**写盘(专辑预取最多 30 首逐个落盘/译文回填/重打分)也会触发重读——闸在 lookup 之后比较「曲目身份+五个歌词字段+简繁偏好+卡拉OK开关+罗马音语言开关」的完整快照,逐字节没变就直接 return,跳过简繁转换×3/引擎 load/整曲 allLines+gapMarkers 重建(单次 10-50ms 主线程,正撞 30Hz 填色渲染)。⚠️ 三个不变量:快照必含曲目身份(两首都没歌词的歌五字段全空相等,不带身份会串偏移校正);`sawChineseLyrics` 粘性置位在闸前;`clearIfWasPlaying` 清发布状态时必须连带 `lastReloadSnapshot = nil`(否则停播后重播同一首歌 allLines 永远回不来)。「搜索中→暂无歌词」的翻转经 resolved/instrumental 进快照,必穿闸。`allLines` 只在 reload 时重新构造(同一首歌歌词不变),且 Equatable 比较后才赋值(「还没解析完、每轮重试」的分支会反复调 reload,结果都是同一个空)。
- **停止播放清场**(`clearIfWasPlaying`):真停(nil 快照,非暂停)时清曲目/歌词/封面/各判定,**必须连 lastKey 一起清**——否则同一首歌恢复播放时 `trackChanged=false`,allLines/封面两条重建路径全跳过,歌词窗口和悬浮窗显示互相矛盾。
- **UI 状态字段**:`hasLyricsContent`(引擎有无内容)、`isCurrentTrackInstrumental`(纯音乐确证)、`currentTrackHasNoLyrics`(resolved 且无内容且非纯音乐 =「搜过了确实没有」)、`collectorNetworkDown`(collector 报网络不通)、`isCurrentTrackAdBreak`(Spotify 广告:album 空 + bundle id 是 Spotify)。展示面的分支顺序要求:广告/纯音乐/暂无歌词都必须排在「搜索歌词中…」之前,否则永远卡在搜索中。

### PlaybackCoordinator(转发层)

目前只有本地一个数据源,这个类是 `LocalPlaybackSource` 的薄转发,但保留这一层让 UI 不直接碰 LocalPlaybackSource.shared(以后接别的数据源 UI 不用改)。歌词相关职责:

- Combine 逐条把 currentLine/nextLineText/currentLineIndex/allLines/anchor/各状态字段 assign 到自己的同名 @Published;UI 只订阅它。
- 动作转发:`seek(toMs:)`、`nudgeLyricsOffset`/`resetLyricsOffset`/`setGlobalLyricsOffset`/`refreshLyricsOffsetForCurrentTrack`(歌词管理输入框写完 store 后让当前曲目立刻生效)、`refreshLyricsForCurrentTrack`(歌词管理保存/删除后强制重读磁盘)。
- `currentLineDwellSeconds`:当前行会显示多久(相邻两行时间戳之差,最后一行用曲目时长兜底),菜单栏跑马灯拿它配速让一句在换行前滚完。用时间戳**差值**,所以不受偏移校正影响。时间戳乱序/重复时返回 nil(调用方拿它做除数)。

## 设置项

| 设置位置 | 项 | 改什么行为 |
|---|---|---|
| 设置 → 歌词 → 显示 | 卡拉OK效果(`preferWordLevelKaraoke`) | 关掉后 `load(preferWordLevel:false)` 不解析 YRC,一律整行高亮;改动立刻 reload 当前曲目 |
| 设置 → 歌词 → 显示 | 中文繁简切换(`lyricsChineseVariant`) | 不转换/简体/繁体,只影响显示不动缓存;条件显示(见行为规格);立刻 reload |
| 设置 → 歌词 → 显示 | 显示罗马音(japanese/korean/chinese 三个复选框,`romanizationScripts`) | 按整首歌文字种类开关罗马音(服务端字段+客户端兜底一起管);只影响悬浮窗和歌词窗口;立刻 reload |
| 设置 → 歌词 → 显示 | 双行显示(`showNextLinePreview`) | 悬浮窗在当前句下方显示 `nextLineText` 预览;只影响悬浮窗 |
| 设置 → 歌词 → 显示 | 时间轴偏移(播放器下拉框 + Stepper ±5s,步长 0.05s) | 下拉选「全部播放器」→ `LyricsOffsetStore.globalOffsetMs`;选具体播放器 → `playerOffsets[bundleID]`。两档**二选一不相加**,再与单曲微调相加;标题/副标题/help 是**固定文案**、不随选中项变;下拉框选中态是纯 `@State`、**不持久化** |
| 设置 → 快捷键 | 调整步长(`lyricsOffsetStepMs`,默认 200ms) | 菜单/快捷键每次 nudge 的幅度(不影响设置页全局偏移的 0.05s 步长) |
| 菜单栏 → 歌词时间轴 | 提前/延后/重置 | 单曲微调 nudge ±step / 清零;菜单标题显示单曲部分的累计值 |

这些设置全部走「双写」模式:AppSettings 负责持久化,LocalPlaybackSource 的同名属性负责让当前曲目立刻生效(didSet → reload);App 启动时 AppDelegate 把持久化值推一次给 LocalPlaybackSource(LyrimuseCore 层够不到 AppSettings)。

## 与其它功能的交互

- **collector(进程边界)**:歌词内容的唯一生产方,独立进程写 `lyrimuse-enrich-cache.json`;App 侧靠 mtime 感知重写(同一首歌中途补译文/换歌词自动生效)。key 归一化两侧必须逐字节一致,selftest 锁死。署名行过滤跟 collector 侧 `match.go` 是同一条结构正则、不同爆炸半径(那边整份拒收计数、这边逐行展示过滤),规则**不能原样搬**。
- **歌词管理窗口**:保存/删除歌词后调 `PlaybackCoordinator.refreshLyricsForCurrentTrack()` 强制重读(默认只在换歌时 reload);偏移输入框直接写 `LyricsOffsetStore.setOffset`,再调 `refreshLyricsOffsetForCurrentTrack()`;它算 offset key 用的是**磁盘持久化后**的歌词内容(内容指纹要跟引擎读到的一致)。用户在歌词管理里换/改歌词 → 内容指纹变 → 该歌旧微调自动失效(查不到即 0)。
- **播放进度链(第 07 章方向)**:本章的行定位完全依赖 `anchor`/`pausedPositionMs`(位置平滑、伺服校正、seek 陈旧读数拒收都在 LocalPlaybackSource 位置侧);逐字填色是 View 层拿 anchor + `SyncedLyricWord` 时间戳现算,不经过 currentLine。歌词窗口点行 seek 用 `timeMs - currentLyricsOffsetMs` 反算目标——必须用引擎实际生效的总偏移。
- **对唱分栏(LyricDuet)**:`SyncedLyricLine.side` 由 load 时算好,悬浮窗/歌词窗口按 side 排版并叠加 `LyricDuetLayout` 的两侧内缩,nil 各自兜底、且不吃内缩。灵动岛/菜单栏面板/菜单栏状态项**刻意不做**对唱(单行显示靠对齐表达不了,2026-08-23 产品决定)。
- **封面链**:`EnrichCacheReader.coverURL/nativeSizedCoverURL` 被 `PlaybackCoordinator.refreshHighResCover()`(系统封面 <300px 时找高清替代)和 `LastfmStatsService`(最近播放列表封面兜底)消费——歌词缓存文件同时是封面数据源。
- **菜单栏跑马灯**:`currentLineDwellSeconds` 配速;菜单栏歌词只消费 `plainText`。
- **诊断导出**:`lastResolvedBundleID`/`resolvedPlayerDescription` 报实际在播的播放器(与歌词无直接关系,但同在这条转发层)。

## 数据与文件

| 位置 | 读/写 | 内容 |
|---|---|---|
| `~/.config/lyrimuse/lyrimuse-enrich-cache.json` | App 只读(collector 写) | 歌词四字段 + instrumental + ts + 封面 URL,key 为归一化「歌手\|歌名\|专辑」 |
| UserDefaults `np:lyricsOffsetsByTrackJSON` | 读写 | 单曲偏移字典的 JSON 字符串(key 含内容指纹) |
| `~/.config/lyrimuse/lyrimuse-lyrics-pins.json` | App 写(collector 只读) | 已校准名单:归一化 enrich key → 记下这条 pin 的 unix 秒。collector 靠它一票否决自动重选歌词源 |
| UserDefaults `np:lyricsGlobalOffsetMs` | 读写 | 全局偏移(裸 Int,缺失即 0) |
| UserDefaults `np:lyricsOffsetsByPlayerJSON` | 读写 | 按播放器偏移字典的 JSON 字符串(key 是 bundleID;零值不落盘,所以字典里就是真的配过的那几个播放器) |
| UserDefaults `np:preferWordLevelKaraoke` / `np:romanizationScripts` / `np:hasSeenChineseLyrics` / `np:lyricsOffsetStepMs` | 读写(经 AppSettings) | 显示相关设置持久化;繁简档位同为 AppSettings 持久化(`lyricsChineseVariant`) |

进程边界:collector(Go,launchd 常驻)负责联网解析并写缓存;App 进程只读缓存 + 读 `CollectorStatus`(网络状态)。引擎全链在主线程(@MainActor),缓存文件读取本身同步(mtime 缓存把代价压到只有文件变了才解析)。

## 代码锚点

| 主题 | 文件 + 符号 |
|---|---|
| 引擎主体/查询接口 | `lyrimuse/Sources/LyrimuseCore/Lyrics/LyricsSyncEngine.swift` — `LyricsSyncEngine.load/activeLine/activeLineIndex/upcomingLineText/allLines`、`offsetMs` |
| 署名行过滤规则族 | 同上 — `creditLinePattern`、`creditRoleWords`/`matchesRoleWordCredit`、`matchesEnglishCredit`、`matchesLatinCreditPattern`、`looksLikeHeaderLine`、`speakerLabels`、`shouldApplyStructuralCreditFilter`、`strippingCreditLines` |
| 行/词数据模型 | 同上 — `SyncedLyricWord`、`SyncedLyricWordGroup`、`SyncedLyricLine`、`LyricsWindowLine` |
| LRC 解析(含 CRLF) | `LyrimuseCore/Lyrics/LRCParser.swift` — `LRCParser.parse` |
| YRC 解析(含畸形元组) | `LyrimuseCore/Lyrics/YRCParser.swift` — `YRCParser.parse`、`wordRegex`、`malformedTupleRegex` |
| 偏移存储与合成 | `LyrimuseCore/Lyrics/LyricsOffsetStore.swift` — `LyricsOffsetStore.trackKey/baseOffsetMs/effectiveOffset/globalOffsetMs/playerOffsets/playerOffset/setPlayerOffset/nudge/setOffset` |
| 偏移作用域下拉框候选 | `LyrimuseCore/Lyrics/LyricsOffsetScope.swift` — `LyricsOffsetScope.options/allPlayersTag`(纯函数,selftest 覆盖四条不变量:排除 `.auto`、配过偏移的必列、顺序稳定无重复、`builtInOrder` 参数生效) |
| 罗马音/语言判定/简繁 | `LyrimuseCore/Lyrics/Romanizer.swift` — `Romanizer.romanize/japaneseSegments/looksJapanese/script`、`ChineseVariant.converted`、`RomanizationScripts` |
| 异体字规范化表(繁简之外的一层,有 selftest) | `LyrimuseCore/Lyrics/HanVariants.swift` — `toSimplified`、`normalizeToSimplified` |
| 假名标注 | `LyrimuseCore/Lyrics/KanaAnnotation.swift` — `KanaAnnotation.parse/marks` |
| 对唱分栏 | `LyrimuseCore/Lyrics/LyricDuet.swift` — `speakers/plan/planWords/sides/identity`;两侧内缩在 `LyricDuetLayout.swift` |
| 缓存直读 | `LyrimuseCore/Local/EnrichCacheReader.swift` — `EnrichCacheReader.lookup/looseMatch/fileModificationDate/coverURL/nativeSizedCoverURL` |
| key 归一化/宽松键 | `LyrimuseCore/Local/EnrichCacheKeys.swift` — `EnrichCacheKeys.normalizedKey/normalizedTitle/cleanTag/looseKey` |
| 消费链宿主/20Hz | `LyrimuseCore/Local/LocalPlaybackSource.swift` — `reloadCurrentLyrics/fastTick/resolveLinesForPausedPosition/applyOffsets/apply/clearIfWasPlaying`、`currentOffsetKey`、`sawChineseLyrics` |
| UI 转发层 | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` — `PlaybackCoordinator.start/currentLineDwellSeconds/nudgeLyricsOffset/refreshLyricsForCurrentTrack/seek` |
| 设置入口 | `lyrimuse/Sources/lyrimuse/SettingsView.swift` — `displayCard`、`romanizationToggle`、全局偏移 SettingsRow;`lyrimuse/Sources/lyrimuse/AppDelegate.swift` 启动推送设置 |
| 菜单/快捷键偏移 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusMenu.swift` — `offsetMenuTitle/nudgeEarlier/nudgeLater/resetOffset`;`lyrimuse/Sources/lyrimuse/Settings/GlobalHotkeys.swift` |

(LyrimuseCore 路径均在 `lyrimuse/Sources/` 下。)

## 设计决策与已知坑

1. **逐字填色不预烤进 @Published**:曾经在 20Hz tick 里预算 fillFraction 再靠 `.animation(.linear)` 补间,SwiftUI 对不可合并曲线是新旧位移矢量相加而非接续,补间时长(60ms)>tick 间隔(50ms)时几乎总被打断——这是逐字卡顿的结构性根源。现在只发真实时间戳,View 按帧现算(`SyncedLyricWord` 顶部注释)。
2. **CRLF 是一个扩展字形簇**:`split(separator:"\n")` 切不开 `\r\n`,酷狗社区上传约半数是 CRLF;LRC 侧后果是「整个桌面都是歌词」。Python 分析查不出,必须在 Swift 里验证(两个 Parser 的归一化注释)。
3. **署名行过滤的爆炸半径**:同一条结构正则在 collector 侧误判一行无害、在展示侧误判一行就是静默吞真歌词——所以有「≥3 且过半」闸门、说话人豁免、永不删空三重护栏;枚举法收敛不了(至今补到第八轮),新增规则优先走「形状/双字包含」而不是加关键词。
4. **YRC 退化要看覆盖率不是非空**:「有 YRC 就用」曾让某歌整首卡在唯一幸存的一行上;判据是逐字行数 ≥ 整行的一半。
5. **罗马音兜底必须按行缓存**:activeLine 每 tick 重新构造,不缓存时纯英文歌每秒 20 次 ICU 音译,表现为本地歌词进度可见地慢于网页端。
6. **日文汉字不能走 Any-Latin**:假名出罗马字、汉字出拼音混一行;整首粒度判日文(局部纯汉字日文行会被误判中文),日文读音吃上下文所以整行分词再按 UTF-16 对回。
7. **偏移 key 必须含内容指纹**:曾有消费方自己拼 `"artist|title"` 查 store,跟实际存储 key 对不上,「提前」生效了但菜单永远显示 0;现在统一转发 LocalPlaybackSource 的权威值,合成只在 `effectiveOffset` 一处(两处各加一次 = 双倍校正)。
8. **同一个功能删了又加回来,必须换新键**:按播放器偏移 08-18 加 → 08-20 因根修下线**并清掉存量值** → 08-21 按用户要求以不同语义(用户显式配置、界面可见可重置)加回。复用旧键 = 把那些为已经修好的 bug 调出来的旧值重新激活,而回归的表现是「歌词莫名被拖慢」、界面上完全看不出来。selftest 有一条落盘原文断言钉住旧键始终为空。
9. **繁简折叠绝不进 key**:Go(OpenCC)和 Swift(ICU)对部分字取舍不一致,进 key 是整首没词,放查询兜底层折不对只是多一条重复条目(`EnrichCacheKeys.looseKey` 注释)。
10. **@Published 值变才赋值**是全链纪律:SwiftUI/Combine 不比较新旧值,fastTick 的三个字段、apply 的曲目字段、reload 的 allLines 全部先比较再赋值——违反任意一处就是每秒 20 次(或每 2 秒一次)的全 body 重算。
11. **暂停 ≠ 清空**:「停止推进」和「清空显示」是两回事;暂停按冻结位置解行,且 apply/fastTick 必须共用同一份逻辑(曾错开:暂停下拖进度条行被清、要等 2s 轮询才回来)。
12. **`LyricsOffsetScope.options` 的内置播放器顺序是调用方传进来的参数,不是它自己认的**(2026-08-25):新增 `builtInOrder: [PlaybackPlayer] = PlaybackPlayer.allCases` 参数,默认值保持旧行为(枚举声明顺序),但设置页"全局时间轴偏移"那一行的下拉框调用点显式传 `PlaybackPlayer.displayOrder`(按系统语言排,跟"选择播放器"图标网格——见 02-playback-source.md——同一套顺序,用户要求两处一致)。**为什么不让这个函数自己去读 `displayOrder`**:`LyricsOffsetScope` 在 LyrimuseCore,而 `displayOrder` 定义在 App 主 target 的 `FeatureSettingsStore.swift`(依赖 `AppSettings.userReadsSimplifiedChinese`),LyrimuseCore 不能反向依赖 App target(AGENTS.md 的分层约定)——顺序只能作为参数从外面传入,这也是这个仓库里"纯函数 + 依赖注入"处理跨层顺序需求的标准做法。

⚠️**待核对**:按播放器偏移对浏览器**实际有多少用**,仓内没有实测记录。02-playback-source.md 记着两条相关实测:一是「没有可学的常数」(Δ位置−Δts 七个样本极差 1.03s,所以自动学一个偏移不可行),二是时间戳相位订正已把平均绝对误差从 0.653s 压到 0.163s。残余偏差是否真接近常数、用户手调一个固定值能不能明显改善 Arc 的观感,**都还没量过**。这一层的正确性(存储、分层、不串台)有 selftest 钉住,「有效性」是待核对的。

其余行为均以当前工作树代码及其注释为准核对过。

# 03. 封面链路
> 最后核对:2026-09-09 · 基线:b7e08ef+工作树

## 定位

把「当前正在播的这首歌的专辑封面」从系统 Now Playing 里取出来、验明正身、必要时换成高清版,再派生出两种动态强调色,供 App 内四个图像消费面和多处文字/控件着色使用。整条链路对用户不可见——用户只看到封面出现在哪里、颜色跟着封面变。

## 入口与展示面

封面没有直接操作入口,只有展示面。图像消费面四个:

1. **灵动岛歌词行尾的封面小图**(卡片右下角,32pt 见方)
2. **灵动岛「跟随封面」背景**(风格选 coverArt 时,模糊封面铺满卡片)
3. **歌词窗口的模糊背景**(Apple Music 歌词页式的放大模糊+压暗)
4. **歌词窗口左栏的封面卡**(最大 460pt 的清晰方图)

颜色消费面(均值取色链的下游):

- 桌面悬浮歌词的前景文字色(「跟随封面取色」开着时)
- 灵动岛整套 UI 着色(歌词、歌名、播放指示条、控制按钮、进度条、瞬态提示条)
- 设置页「歌词显示」里的两块编辑台(`OverlayEditorStage` / `NotchEditorStage`,画的都是真视图)

悬浮歌词(LyricsOverlayView)**不**显示封面图,只吃颜色;菜单栏歌词跟封面链路完全无关。

## 行为规格

### 1. 系统封面获取(换歌触发,不在轮询里)

- 取图只在 `LocalPlaybackSource.apply()` 检测到 `trackChanged`(trackKey 变化)那一刻触发一次,调 `fetchArtworkForCurrentTrack(expectedKey:)`;不掺进 2 秒一次的常规轮询(常规轮询传 `--no-artwork` 省掉几百 KB base64)。
- 底层是 `MediaControlClient.fetchArtwork()`:**所有播放器(含 Apple Music)统一**走内置 media-control 二进制 `get --now`(实测 Apple Music 的系统级会话同样带 artworkData,不必再开 AppleScript 取图路);超时 10s(`artworkTimeout`,比状态查询的 5s 宽);核对载荷 `bundleIdentifier`——选了具体播放器要求精确匹配,`.auto` 认四个已知播放器之一,对不上(Now Playing 焦点被网页视频等抢走)返回 nil。返回 `(data, mimeType, trackKey)`,其中 trackKey 是**载荷自带的** artist|title(`MediaControlSnapshot.trackKey`,跟快照那边同一推导,不能各写一份)。

**载荷曲目标识校验**:一次取图算「定案」要同时满足①拿到图②载荷 trackKey 与 expectedKey 匹配(`artworkKeyMatches`,**大小写不敏感**——media-control 对同一首歌报过大小写不一致的元数据,严格比对会让那类歌永远占位)。切歌瞬间系统侧条目可能还是上一首的(旧标题+旧封面),载荷自己的标识是识别这种情况的唯一依据——不匹配按「系统还没更新完」重试,绝不把上一首的封面挂到新歌上(2026-08-17 网易云云盘歌「沿用上一首封面」后补上)。

**取图重试**:没定案(没拿到图,或标识对不上)按 `artworkRetryDelays = [0.3, 0.6, 1.2]` 秒递增重试,总共最多 4 次 attempt。每次重试前核对 `expectedKey == lastKey`,期间换了歌就整轮放弃,交给新一轮。重试打满仍是别的歌的封面 → 置 nil 宁可占位不挂错图,并留 info 日志(万一两条路径的元数据出现系统性偏差,每首歌都会触发,靠日志定位)。

**换歌时不立即清旧封面**:2026-08-02 版本是立即清,2026-08-05 反转——清空会让歌词窗口整窗从「封面模糊底+白字」回落到「系统背景+主文字色」,浅色外观下就是整窗白闪,比「旧封面多挂 200~500ms」糟得多(Apple Music 自己也是留旧图到新图交叉淡入)。新图到货才替换,确认这首歌没封面(定案为 nil)才在那一刻清空。

**3 秒陈旧兜底**(`scheduleArtworkStaleTimeout` / `artworkStaleTimeout = 3`):取图子进程用 `waitUntilExit()` 且无超时兜不住「真挂死」的情况,旧封面会无限期挂着。换歌时若有旧封面就安排一个 3 秒后清空的任务;取图定案先到会把它取消。⚠️注意每次重试前都会**重排**这个任务——「3 秒」是「距最后一次尝试 3 秒」,否则重试链(4 次子进程各几百毫秒)可能还没跑完兜底就先开火,重演白屏。

**3 秒二次确认**(`artworkConfirmDelay = 3`):首轮定案后再等 3 秒取一次。防的是「新标题+旧封面」的合体载荷——系统侧先换标题、封面字段晚一拍,这种陈旧带着**新歌**的标识,首轮比对拦不住。顺带接住「播放器中途升级封面」(网易云先给占位图、匹配到曲库后换真图)。只在确认结果非空、属于这首歌、且字节数不同于当前那份时才替换;一次瞬时读取失败不会抹掉已挂好的封面。

**定案落库**:`artworkData`(原始字节)和 `artworkAverageHex`(均值色,同一个后台 Task 里 CIAreaAverage 算好)同时发布,共用同一套 expectedKey 换歌校验。停播(快照变 nil / bundleID 对不上)时 `clearIfWasPlaying()` 把两者连着 `lastKey` 一起清空——lastKey 不清的话同一首歌恢复播放时 trackChanged 恒 false,封面永远回不来。

### 2. 网易云小图 / 云盘占位图问题

- 网易云 macOS 客户端给系统 Now Playing 的封面**恒为 100×100**(2026-08-17 实测:7.3KB JPEG,`get`/`get --now` × 自带/homebrew 两份 media-control 四种组合全是这个尺寸;media-control 没有「要大图」的参数)。放到歌词窗口 460pt(Retina 920px)的封面卡等于放大 9 倍,就是用户报的「封面非常模糊」。
- 网易云**云盘**歌曲(未匹配到曲库)系统给的是灰底红音符占位图——2026-08-17 实测(《以父之名》):**100×100、2345 字节 JPEG**,同样 <300px,所以高清替代照常触发,缓存里解析到真封面时展示面铺真封面而不是占位图,强调色也按真封面算(见下面 highResAverageHex)。缓存查不到封面的极端情况才会一直显示占位图。

### 3. 高清替代(`PlaybackCoordinator.refreshHighResCover`)

- **触发**:`CombineLatest4($title, $artist, $album, $artworkData)` debounce 300ms 后调用。⚠️debounce 不是省请求,是**避开 @Published 的 willSet 时机**——订阅回调跑在值还没落库那一刻,回调里读 self 的其它属性可能读到上一首的值(本项目为此踩过两次坑);函数体也因此**刻意从 `LocalPlaybackSource.shared` 重新读快照**而不用回调参数。这 300ms 用户无感,系统小图第一帧已经显示。
- **门槛**(`lowResArtworkThreshold = 300`):用 CGImageSource 只读图头取系统封面的像素**宽高**(`pixelSize(of:)`,不解码整图),判定收在 `CoverArtReplacementGate.reason`(LyrimuseCore,selftest 直接断言)。两个触发条件任一成立才找替代:① **太小**——`0 < 宽 ≤ 300`;② **不是封面的形状**——长宽比偏离正方形超过 15%(`maxAspectSkew`,跟 collector `deviceArtworkMaxAspectSkew` 逐字一致;2026-09-08 加,YouTube Music 的 MV 条目上报的是 320×180 视频缩略图,见决策 15)。形状先于尺寸判,1280×720 的视频帧再大也不是封面。都不成立就不动——系统没给封面(宽 0)时该显示占位音符,不该悄悄换成缓存匹配出来的另一张图;正常给大图的播放器(Apple Music)一次都不会触发。300 的依据:封面卡 920px / 300px 已是 3 倍放大。
- **替代图来源**:`EnrichCacheReader.albumMatchedCoverURL(artist:title:album:)`,读 collector 解析歌词时顺手记下的 `cover_url`(网易云/Apple/QQ),两级查找:归一化 key 精确命中 → looseMatch(忽略空格/大小写/繁简,但仍然认专辑)。**不**退到「歌手|歌名」忽略专辑的那级索引——系统这份的专辑名来自 Now Playing、就是当前真正在播的这一版,退一步反而是拿错版本的风险(2026-08-26 用户报的方大同「放不过自己」实锤:缓存里同名不同专辑的两条记录封面完全不同,退到忽略专辑那级会随机凑到错的那条;`coverURL(artist:title:album:)` 保留三级查找给「最近播放」/待机页那两个专辑名本就不一定可信的消费方用,见 `EnrichCacheReader.swift` 两个函数各自的注释)。再经 `nativeSizedCoverURL` 处理:**只对网易云图床**(`*.music.126.net`)去掉 `?param=600y600`——那个参数只降不升(实测原生 800×800 带 param 拿回 600×600,`param=1200y1200` 也不上采样),去掉才拿得到原图;别的图源参数未核实,不动。
- **Spotify 原生客户端另有一条「同一张图的原图档」替代路**(2026-09-09,`PlaybackCoordinator.refreshSpotifyOriginalCover`):Spotify 交给系统的封面实测是 600×600(与 Spotify 图床 640 档同一张图,8×8 均值哈希距离 0),又方又不小,永远不进上面那条门槛;但歌词窗口那张卡要画到 920px。`SpotifyPositionProbe` 开播 2.5s 后那次 AppleScript 顺带带回 `artwork url`(640 档),App 按 `SpotifyArtworkURL.downloadCandidates` 先取 `82c1` 原图(实测 800 / 1425 / 2000)、取不到退 640,拿回来的比系统那份宽就换上 —— ⚠️ 两边都按**像素**(`NSImage.pixelWidth`,CachedImage.swift 里的 extension;`ImageMemoryCache` 的 cost 也同批改成按像素算)比,不能用 `NSImage.size`:Spotify 图床的 JPEG 带 797 dpi 的密度标签,2000×2000 的原图 `size.width` 只有 181 点,第一版装机就是在这里把原图当小图丢掉的(2026-09-09 现场日志「181px is not larger than system 600px」);网易云/QQ/Apple 的图没有 DPI 标签、点数恒等于像素,上面那条路原来也用 `size.width`,一直没出事只是巧合,2026-09-09 同批改成像素。身份由播放时刻保证、不靠文字匹配,所以不需要 `CoverArtReplacementGate` 那套判据;换歌置 nil、旧图由上面那条路的 clearHighRes 撤;网页版 Spotify(Safari 实测 MediaSession 给的封面是 640×640)由 `BrowserPositionProbe` 从页面 `cover-art-image` 带回同一格式的地址、走同一条路(2026-09-09,见 02 章「Spotify Web」小节);订阅跟 `$artworkData` 合在一起、比高清替代多等 50ms,保证 refreshHighResCover 因封面字节重发而清空之后能按同一地址从内存缓存原样放回(`spotifyCoverAppliedURL`)。⚠️ 原图档尺寸不定,单张最大实测 827 KB、解码 16 MB,跟网易云 3000² 原图同一档待遇。
- **换歌时立刻撤掉上一首的高清图**(和均值色同进退)再异步下载——留着的话新图下载完之前会显示上一首的封面,比「先小图后变清晰」糟得多。
- **下载**走 `ImageMemoryCache.shared.load(url, variant: .original)`(同 URL 并发只发一次请求;底层 URLSession.shared 吃 URLCache 磁盘缓存;原图档——这张要给 920pt@2x 的封面卡,不能吃缩略降采样)。回来后三道守卫:任务未取消、`LocalPlaybackSource.shared.title` 还是发起时那首、**替代图值不值得换按触发理由分**(`CoverArtReplacementGate.accepts`):太小那条要求拿回来的宽度大于系统那份(缓存里可能存着一张同样小的图,不值得换;宽度按**像素**比 —— `NSImage.pixelWidth`,取自第一个 representation 的图头 —— 不是 `NSImage.size` 的点数,DPI 坑见下面 Spotify 那条);形状那条只要求替代图自己是方形——换的是形状不是分辨率,不能再拿「比系统那份宽」当门槛,否则 1280×720 的视频帧会把 600×600 的真封面挡在外面。
- **均值色同步给**:`highResAverageHex` 用 `LocalPlaybackSource.computeAverageHex(cgImage:)` 后台算,跟图一起赋值。有高清图时两条强调色管线**必须**按它算——系统那份可能是灰底占位图,界面实际显示的是高清替代,强调色还按占位图算就是一团无关的灰。
- 替代关系是「只替不动权威」:系统那份才是「正在播的这一项」的权威图,缓存那张是按歌手/歌名/专辑**匹配**出来的,同名不同版本可能是另一张封面,所以只在系统那份确实太小、或者压根不是封面形状时才替。

### 4. 均值取色链(两条管线、不同亮度规则)

数据层只出**未经调整的原始均值**:

- `LocalPlaybackSource.artworkAverageHex` —— 系统封面的 CIAreaAverage 均值,`#RRGGBBAA` 十六进制字符串(LyrimuseCore 不引 AppKit/SwiftUI,hex→Color 由上层做)。⚠️2026-08-17 起这里**不再提亮**(旧名 artworkAccentHex 顺手调过 brightenedAccent)——两个消费面对「该多亮」的要求正好相反,提亮按消费面各自处理。
- `PlaybackCoordinator.highResAverageHex` —— 高清替代那张的均值,nil 表示没有替代。

两条管线在 `PlaybackCoordinator.start()` 里各自订阅,都优先吃高清均值(`highResHex ?? systemHex`),每首歌只算一次;输出都带 `removeDuplicates`(2026-08-20:高清 hex 的 nil 重赋值这类输入抖动不再让 coordinator 的全部观察面白挨 objectWillChange)。取色的 `CIContext` 进程级复用一份(原来每次取色新建,~15ms/个);系统封面的取色只在**定案采纳**那一刻算(原来 attempt 顺手预算,重试丢弃/confirm 字节相同这些注定丢弃的路径每次白算一遍);confirm 先比字节再取色。高清封面刷新的四条清空路径都加了「已是 nil 不再赋」的闸,加上烘焙订阅的恒等去重,同一张源图不再被重复烘两份 720px 模糊(每次换歌省 1-2 次全套高斯烘焙):

| 管线 | 消费面 | 亮度规则 |
|---|---|---|
| `artworkAccentColor` | 桌面悬浮歌词前景色 | 背景是壁纸/任意窗口,不能假定深浅。描边开着且描边色 alpha ≥ 0.5 时走 `accentAgainstStroke`:判据是**跟描边色的 WCAG 对比度 ≥ 3.0**(字直接相邻的永远是描边),近黑先换成同亮度中性灰(只丢不可信色相、保留「它很暗」),不够对比就沿「离开描边亮度」的方向二分混合(比描边亮→朝白,比描边暗→朝黑压暗)。描边关着(或太透明)退回 `brightenedAccent`「保证够亮」的老规则。**因此这条管线依赖描边两项设置,改描边会连带重算**。 |
| `notchAccentColor` | 灵动岛整套着色 | 背景永远深色(三种风格底色全暗),判据是「够亮」:先 `brightenedAccent`(HSB 亮度地板 0.62,近黑兜底成 0.72 中性灰,提亮多少就按比例压饱和),再 `accentForDarkBackdrop` 补一道 Rec.709 感知亮度下限(HSB 地板拦不住饱和冷色——纯蓝 brightness 满格但 luma 只有 0.07,朝白线性混合解析提到 0.62)。 |

下游取用:

- `PlaybackCoordinator.displayForegroundColor`:「跟随封面取色」(followsCoverArt)开着且 `artworkAccentColor` 非 nil → 用它;否则退回设置里手选的 `foregroundColor`。只被 LyricsOverlayView 消费。
- `NotchLyricsView.accentOrWhite`:followsCoverArt 开着且 `notchAccentColor` 非 nil → 用它;否则纯白。灵动岛歌词/歌名/EqualizerBars/控制按钮/进度条/瞬态提示条全走它(封面小图的描边投影除外)。
- 设置页悬浮歌词编辑台画的是真 `LyricsOverlayView`,`$artworkAccentColor` 经它自己的窄订阅代理 `OverlayPlayback` 生效,不再有单独的预览订阅(旧的 `OverlayPreviewBar` 2026-08-31 已删)。

### 5. 图像消费面(六处)

所有图像消费面读的都是 `poller.highResArtworkImage ?? poller.artworkImage`——**解码收敛在 PlaybackCoordinator**:`artworkData` 变化时 `NSImage(data:)` 只解一次(`artworkImage`),灵动岛一个 body 里两处读封面不会把同一张几百 KB 的 JPEG 每次重算 body 都解两遍。

⚠️ **这条口径是每个消费面自己的义务,漏了不报错**。下面列的四处之外还有两处后来加的:**菜单栏快捷面板的 44pt 小封面**(`MenuBarPanel.coverView`)和 **Last.fm「正在播放」行的 26pt 缩略图**(`LastfmStatsSection` 的 `LiveRowPlayback`);再加上**灵动岛收起态左耳的小封面**(当时的 `NotchLyricsView.collapsedRow`;2026-09-06 起收起态走同一份 `earArtwork`,不再单独有一处),这三处一直漏着 `?? `,2026-09-02 才由用户报出来 —— 方大同《白发》在 Chrome 里放 YouTube Music 时,系统经 MediaSession 给的是一帧 **150×84 的 MV 截帧**(长宽比偏离正方形 0.44,collector 侧 `deviceArtworkMaxAspectSkew` 正确地没把它当封面收下),于是菜单栏面板画的是那帧 MV、歌词窗口画的是缓存里正确的专辑封面,同一首歌两处两张图。用户原话:「为什么这两个地方的封面不一样?难道取值不一样吗」—— 确实就是取值不一样。

**现在有机械闸**:selftest 扫 `Sources/lyrimuse` 里所有 `.artworkImage` 的**取值点**(排除声明/订阅/赋值/KeyPath),不带 `highResArtworkImage ?? ` 也不走已包好的 `displayArtworkImage` 就红。新增消费面时别绕开它。加闸的理由是这条口径靠"记得写"维护了三个月、漏了三处才被发现,而漏掉既不编译报错也不崩,只表现成"两个地方的封面不一样"。

1. **灵动岛封面小图**(`NotchLyricsView.artworkThumbnail`):歌词行尾端(卡片右下角),边长 `max(16, min(32, 行高-12))` = 32pt,圆角 5pt + 极淡白描边 + 小投影(给磨砂玻璃风格下的浅色封面兜轮廓)。**始终是静态图**——2026-09-09 这里曾叠过一层展开态才播的循环视频,2026-09-10 用户看过实机后撤掉(见第 6 节末尾「只留歌词窗口」)。没有封面数据**整个不占位**(不画空方块)——换歌时旧图留到新图到货,只有「启动后第一首」和「这首歌真没封面」才发生一次宽度增减。这枚小图无开关(2026-08-10 删掉「显示专辑封面」开关,固定有图就显示)。
2. **灵动岛「跟随封面」背景**(`NotchLyricsView.backgroundLayer`):`notchCardStyle == .coverArt` 且有图时,封面 scaledToFill + blur 20 + 45% 黑,底下先铺一层不透明的 darkGradient 打底(blur 会把图像边缘羽化成半透明,没有打底卡片四周会透出桌面)。模糊半径 20 远小于歌词窗口的 72——灵动岛 4.7:1 又矮又宽,照搬大半径会把任何封面抹成统一深灰。没图(或风格不是 coverArt)退回所选固定风格的填充。
3. **歌词窗口动画背景**(`LyricsWindowView.artworkBackground`):AM 式「暗底+lighten 光斑+慢旋转」,图层预烘焙(`bakeWindowBackgroundLayers`:暗底 + 3 张分区取色羽化光斑,seed 确定性),视图层仅 GPU 变换动画 + 0.15 遮罩——细节与四轮校准史见 07-lyrics-window.md。
4. **歌词窗口封面卡**(`LyricsWindowView.artworkCard`):左栏 1:1 方图(Color.clear 撑框 + scaledToFill),最大 460pt;没图画灰底 music.note 占位。**有动态封面时在静态图之上叠一层循环视频**(见第 6 节;静态图始终铺在底下,没有/还没下好就只有它)。卡片实际宽度回写 `artworkWidth`,整排播放控制按钮按它缩放。0.5s 交叉淡入动画收在 overlay 内容上而不是卡片最外层(挂外层会把同事务里的布局位移一起 animate 成「进度条从上面飘下来」)。

**小图不在运行期缩**(2026-09-09,用户圈图:灵动岛左耳那枚封面「和大图长得不一样,上面有黑斑,展开的时候黑斑还会动」——陶喆《I'm O.K.》,黄底黑点的半调网点封面):所有**小尺寸**消费面(灵动岛三枚 `artworkThumbnail`:左耳 ~23pt / 歌词行末尾 32pt / 展开头部;菜单栏面板 44pt `coverView`;Last.fm「正在播放」行 26pt 的本机位图兜底)统一先经 `ArtworkThumbnailCache.bitmap(for:pixelSide:)` 按 **pt × 显示倍率**预先重采样成位图(`ArtworkThumbnail.squareBitmap`,LyrimuseCore:aspect-fill 居中裁方 + CoreGraphics `.high` 插值),再用 `Image(decorative:scale:)` 逐像素贴 —— 跟左耳 App 图标(`NotchIdleAppIcon`,05 章决策 #30)同一招。原因:`Image(nsImage:).resizable().scaledToFill()` 把 600px 源一步缩到 46px 走的是线性采样、**没有面积平均**,半调网点跟采样网格打拍就是几块跟原图无关的大黑斑,且展开动画里亚像素相位每帧变、黑斑跟着"动"(离屏复现:相位差 0.37px 图案全换;`.high` 重采样后与大图一致)。缓存按 (源图身份, 像素边长) 存、持有源图强引用防 `ObjectIdentifier` 复用、只留最近两张源图;600px JPEG 缩到 46/64/88px 各约 4~9ms、每张每尺寸一次。歌词窗口 460pt 那张接近原生尺寸,不走这里。selftest `cover-art` 组用 1px 黑白棋盘格钉「缩出来全是灰、朴素采样对照组过半是黑白极值」+ 横/竖图居中裁方。

**共同细节**:换图动画的触发键有两个——原始字节 `poller.artworkData`(Data 按字节比较,保持跟加解码缓存之前逐字节相同的判定语义;`artworkImage` 是 NSObject,== 退化成指针比较,语义不等价)和 `poller.highResArtworkImage`(这里指针比较反而是对的:每次到货都是新解码的实例)。灵动岛背景和小图的 `.scaledToFill()` 之后、`.clipShape` 之前必须显式钉一次 `.frame(width:height:)`——scaledToFill 会向布局系统请求比可见区更大的 frame,clipShape 按紧邻上一个 View 的 frame 算圆角,不钉的话圆角落在偏大矩形的边缘,可见区域实际是直角(像素级采样验证过,肉眼会被模糊骗)。

**文字配色联动**:歌词窗口 `hasArtworkBackground = poller.artworkData != nil`——只看系统那份、不看高清替代(高清替代只在系统有图且太小/不是方形时才存在,所以两者有图性一致)。它为 true 时全窗文字切固定浅色系(.white 系),false 时用系统 .primary/.secondary;空状态占位(ContentUnavailableView vs 自绘白色版)、进度条/按钮的 rim 色、封面卡投影深浅也都随它切。

### 6. 动态封面(Apple Music motion artwork,2026-09-09)

Apple Music 给**一部分**专辑配了循环动态封面。这一节讲我们怎么把它找出来、放在哪、以及为什么它只在少数时候出现。用户原话:「帮我看看怎么把我们的封面搞成 applemusic 里面的那种会动的效果」。

**这条链路跟上面的静态封面是并行的两件事,不互相替代**:静态图管「这一格画什么」(而且始终铺在底下),动态封面只是在它之上再叠一层会动的画面;拿不到就什么都不叠,界面回落到静态图,用户无感。也因此它**不参与均值取色** —— 强调色仍按静态图算,否则同一张专辑会因为「动画播到哪一帧」而颜色抖动。

⚠️ **唯一的落点是歌词窗口那张封面卡(`LyricsWindowView.artworkCard`,最大 460pt)**。落地当天灵动岛的封面缩略图也叠了一层(只在展开态播),2026-09-10 用户看过实机后拍板撤掉 —— 原话:「帮我把灵动岛上的封面全部改为静态的吧,只有歌词窗口的保留;因为灵动岛上的效果不是很好」。**撤的理由是尺寸,不是实现**:灵动岛那一格最大也就 `NotchMetrics.trackInfoArtworkSide` 这个量级、歌词行尾/耳朵那两档只有 32pt,而 Apple 的 motion artwork 是给整张专辑封面设计的慢镜头,缩到这么小只剩一片蠕动的色块、看不出画的是什么。别再"顺手"加回来:加回来就要重新论证这个尺寸下动效能不能看清,而那已经实测过一次了。

**数据流**(四段,每段都能独立失败而不影响别的):

1. **发现**(collector,`motioncover.go`)。按专辑 ID(两条来路,见下面「怎么保证动的就是原来那张封面」)取 `https://music.apple.com/cn/album/x/{collectionID}`,页面里 `<script type="application/json" id="serialized-server-data">` 是一份标准 JSON(实测 109 KB),`…/videoArtwork/dictionary/motionDetailSquare` 就是方形那份:`video` = 一条 master m3u8,`previewFrame` = 静态首帧 + Apple 给的官方配色。slug 那一段写死成 `x` 即可(Apple 只按 ID 定位,实测 200)。存进 enrich 缓存的 `motion_cover_url` / `motion_preview_url`(⚠️ 跟 `qq_album_mid` 同一条:**刻意不进** `fields()`,那张 map 是发给 relay/LB 的载荷、有字节预算,这两个只有桌面端会用)。
2. **推导**(Core,`MotionCoverManifest`,纯函数、selftest 钉着 22 条)。master → 选一档 → 那一档的 variant 清单 → `#EXT-X-MAP` 里那个**单文件**名。
3. **下载**(App,`MotionCoverStore`)。整份下下来存 `~/.config/lyrimuse/motion-covers/<sha>.mp4`,临时文件 + 原子改名,LRU 上限 400 MB。
4. **播放**(App,`MotionCoverLayer`)。`AVQueuePlayer` + `AVPlayerLooper` 无声循环。

**为什么能"下一个文件就完事"**:实测每一档 variant 的分片**全是同一个 `.mp4` 的 byte range**(`#EXT-X-MAP` + 一串 `#EXT-X-BYTERANGE` 都指回同一个文件),底层就是一个完整 fMP4。所以既不必拼分片、也不必上 `AVAssetDownloadURLSession` 那套 `.movpkg` 离线方案 —— 这是整个方案能做成"先下载再本地循环"的前提(用户在两种播放策略里选的就是这个)。

**实测清单**(2026-09-09,全部在 Prince《Timeless》= collectionId 6773830957 上量的):

| 项 | 值 |
|---|---|
| 资源鉴权 | **无** —— master m3u8 与底层 mp4 都是公开 200,不需要 developer token / cookie / Referer |
| 档位 | 360² / 408² / 456² / 486² / 768² / 960² / 1080²,H.264(`avc1`)与 HEVC(`hvc1`)各一份 |
| 帧率·时长 | 24fps,**20.00s** |
| 音轨 | **0 条**(variant 名里的 `Anull` 是实话,`CLOSED-CAPTIONS=NONE`)—— 不会跟正在放的音乐抢音频会话 |
| 单文件大小 | 768² 5.39 MB / 960² 7.17 MB,两份都 `isPlayable == true` |
| 首尾帧 | 缩到 64² 比 R 通道,平均绝对差 **0.58/255**、最大 4/255 → 素材本身就是按无缝循环做的,`AVPlayerLooper` 硬接即可,不需要 pingpong 或交叉淡化 |
| `previewFrame` | 3840² 静态图模板(`1200x1200bb.jpg` 226 KB / `3840x3840bb.jpg` 2.65 MB),另带 `bgColor` + `textColor1~4` 官方配色 |

**覆盖率很低,这是这个功能的形态**:抽 10 张专辑只有 3 张有(Prince《Timeless》、Taylor Swift《1989 (Taylor's Version)》、Michael Jackson《Thriller》);测到的华语专辑一张都没有(五月天《自傳》、方大同《未來》),Billie Eilish《HIT ME HARD AND SOFT》也没有。所以它注定是**"有就动、没有照旧静态"的彩蛋**,不是一个"打开就到处在动"的开关。相应地,collector 必须把**"查过了但这张没有"也落盘**(`Checked` 标记)——否则同一张专辑的每首歌都会重抓一次 330 KB 的页面。这跟 `appleCatalogMisses` 那条"刻意不落盘"相反,理由也不同:那边查空可能只是网络抖动,而"这张专辑没做动态封面"是个稳定事实。

**怎么保证"动的就是原来那张封面"**(2026-09-10,用户提的判据:「可以确保动态的封面就是原本那个匹配到的封面,只是给它扩展成动态吗」)。这是整条链路的**安全底座**,也是它敢把专辑 ID 的来路放宽的唯一原因。

第一版的做法是"只认已校验的目录锚点、绝不按文字匹配猜专辑" —— 覆盖面因此被压在「Apple Music 播的目录曲目」这一档(本机 224 张专辑),QQ / 网易云 / Spotify 播的歌一律没有。但真正要防的从来不是"专辑 ID 猜错"本身,而是"**画面跟用户看到的封面不是同一张**"。**直接比图像**就把这件事从"身份对不对"(靠文字匹配,会错)变成"是不是同一张图"(客观可验):

- **两条来路取专辑 ID**,按可信度排:① 已校验的目录锚点(`appleCatalogAlbumIDFor` → media-control 的 `uniqueIdentifier` 经 iTunes lookup,02 章「Apple 目录锚点」),ID 精确但只有 Apple Music 播的目录曲目才有;② enrich 自己记下的 `apple_music_url` 里那个 ID(`motionCoverAlbumIDFromAppleURL`)—— **覆盖所有播放器**,只要 collector 给这首歌匹配上了 Apple 条目就有,但它来自 `searchAppleMusicMatch` 的文字匹配,可能指向另一个版本的专辑(决策 #16 那次错位就是它)。
- **最后一道图像校验**(`motionCoverMatchesCover`):把动态封面的 `previewFrame` 跟**这条记录采用的那张封面**(`cover_url`)比 8×8 均值哈希,距离超过 `coverFingerprintMaxDistance`(10)就当这首没有动态封面。判据与阈值直接复用 `coverquality.go` 那套(它的 10 本来就是拿真实封面校准的:正例 0、反例 17～39)。

2026-09-10 用 5 张真有动态封面的专辑量过,数据比校准时更宽松:

| 比对 | 距离 |
|---|---|
| 首帧 vs Apple 标准封面(4 张) | **1 / 2 / 2 / 1** |
| 首帧 vs **我们实际铺的那张**(网易云源,3 张) | **1 / 3 / 2** |
| 跨专辑对照(16 组) | **19 … 34** |

`3 ↔ 19` 之间是空的,阈值 10 落在空隙正中。跨源那三行尤其关键 —— 我们实际铺的封面多半来自网易云或 QQ,而它跟 Apple 的首帧仍然判为同一张。端到端也验过反例:拿 Timeless 的首帧去比另一张专辑的封面,`distance 31 > 10, skipping`,当场拦掉。

**因此覆盖面**:可查专辑从 224 张涨到 685 张(约 3.1 倍,净新增 461 张、2184 条曲目),而错配风险被图像校验按住 —— 这比第一版**既更宽也更安全**:第一版虽然 ID 精确,却没有任何一道校验能拦住"专辑对但封面不是同一版"。

**逐条记一位"核对过了"**(`motion_cover_checked`)。图像校验没通过、或这张专辑压根没有动态封面时 `motion_cover_url` 是空的,而 `motionCoverWorthBackfill` 光看"空不空"会一直判它缺 —— 每轮 backfill 都重下一次首帧再算一次指纹,白跑 5 轮。⚠️ 它跟 motion 缓存里那个 `checked` 是**两件事**:那个按**专辑**记"这张有没有动态封面",这个按**记录**记"这一条的封面跟那段动画是不是同一张" —— 后者只能逐条判,因为 `cover_url` 是逐条决定的(同一张专辑的不同曲目可能落到单曲封面)。

App 侧仍只走 `albumMatchedMotionCover`(精确 key → 仍然认专辑的 looseMatch),不退到忽略专辑那一级。collector 解析页面时还有一道:找到 `videoArtwork` 之后要在它父节点子树里确认 `storeAdamID == 目标 ID` 才认(实测这一页只有 1 个 `videoArtwork` 节点、相关推荐位不带,这道校验是防将来页面结构变化把邻居专辑的资源喂进来)。

**存量条目怎么补上**(2026-09-09,ls-Alex 交叉核对时点出来的缺口)。`fillMotionCover` 挂在 `resolveTrackEnrichment` 尾巴上,而那个函数对**已存在**的条目只由 `backfillPeripheralFields` 一条路调用 —— 第一版因此有个能让整个功能形同虚设的洞:**缓存里已有的条目一条也补不上**(当时实测 4820 条、`motion_cover_url` 0 条),而用户日常听的绝大多数就是这些。要修的是两处,少一处都不行:

1. **`backfillPeripheralFields` 里要真的把值写进去**。它对已有条目是**逐字段挑着覆盖**的(只在这一轮真拿到时才写,免得一次网络抖动把已存的地址抹成空),不在那份清单里列出来,`fresh` 里算好的 motion 字段就在函数返回时丢掉了。
2. **要有人判定"这条值得补"**。挂在调用点上、跟 2026-09-08 那条 `coverNeedsHintCheck` 完全同构(额外的补齐理由 + 共用同一套上限与节流),**不塞进 `needsPeripheralBackfill`** —— 那个函数被四个测试文件按三参数签名调着,为一条判据改签名不值得。

判据 `motionCoverWorthBackfill` 是**三态**的(2026-09-10 起还多一位「这条记录核对过了」),这半条最要紧:缓存里标着「查过了这张没有」的专辑**不算缺**。动态封面覆盖率只有三成上下,把"就是没有"也算成缺,那七成条目会白重试 5 轮、每轮把开着的歌词源全部重查一遍 —— 跟 `missingQQMids` 那条注释同源的教训。完整四态:已经有了 → 不补;拿不到已校验的目录锚点 → 补也补不出来;缓存里压根没查过 → 值得补一次(查完就落进下面两态);查过了 → 有 master 算缺、没有则不算。

**覆盖面**:实测 4820 条里 4784 条(99.25%)还有 backfill 余量,只有 **36 条**已经打满 5 次上限、拿不到动态封面 —— 那批本来就是有别的字段一直补不上的异常条目,没为它们单独做迁移。要强制全量重来只能删 enrich 缓存,不值得。

**两个消费面**(用户点名的就是这两个):

- **歌词窗口左栏那张封面卡**(460pt,`LyricsWindowView.artworkCard`)。静态图在底下,动态叠在上面,到货/撤掉走跟高清替代同一条 0.5s 交叉淡入。`isPlaying` 跟着 `isPlayingSmoothed` —— 暂停时封面就该停住(它描述的是"这首歌在放"),缓收版能吸掉切歌间隙那一下瞬时 false。
- **灵动岛歌词行尾那枚 32pt 小图**(`NotchLyricsView.artworkThumbnail`)。⚠️ **只在展开态播**:灵动岛是常驻面,而这一格只有 32pt,收起态下动效基本看不出来、却要为它全天候占一个解码器;展开是 hover 才发生、有明确用户意图的时刻。这里用 `isPlayingNow`(`NotchPlayback` 没镜像 smoothed 那份,而只在展开的那几秒播、撞上切歌瞬时 false 的概率很低,不值得多镜像一个字段)。

**刻意没做的**:①**灵动岛整面**都不上动态封面(2026-09-10 用户拍板,理由见本节开头那条 ⚠️);② 灵动岛的「跟随封面」**背景**本来也没上过动态版 —— 它是"背景"不是"封面",而且那一层是**模糊**的,对 24fps 的视频做实时模糊成本远高于收益(模糊之后本来就看不出是不是在动)。

**三道省电闸门**,分两层:

- 收在 `PlaybackCoordinator.refreshMotionCover` 的两条(它们都不是视图环境值,放这里才有唯一真源):用户开关 `motionCoverEnabled`(设置 › 通用 › 封面,默认**开** —— 理由见 `AppSettings.defaultMotionCoverEnabled`)、以及**低电量模式**(`isLowPowerModeEnabled`,变化时经 `NSProcessInfoPowerStateDidChange` 立刻重算)。
- 消费面自己判的一条:`reduceMotion`(环境值,只能在视图里读)。再往下 `MotionCoverNSView` 还有一道:真正离窗时(歌词窗口关掉、切屏幕镜像)把播放器整个放掉,只 `pause` 的话解码器和那 7 MB 映射还挂在进程里 —— 而歌词窗口本来就是按需打开的窗,不开就完全不存在这回事,这也是撤掉灵动岛那份之后省下的最大一块(那是常驻面)。
  ⚠️ 原来这里写的是"三道闸门"、并把"我这一面此刻可不可见(灵动岛的收起/展开)"算作一道;灵动岛那份撤掉后只剩两道。注释里一度出现过的 `MotionCoverGate` **是个不存在的类型**,别去找它。

**⚠️ 这是在解析公开网页里的非公开字段**:Apple 改一次前端结构这条路就断。所以每一层都必须"解析不出来就当这张专辑没有动态封面",绝不把失败往上抛成用户可见的错误 —— 反正覆盖率本来就三成上下,用户对"这首没有"是无感的。要重新试一张专辑就删掉 `lyrimuse-motion-cover-cache.json`(它跟 apple-catalog 那份一样是纯派生数据)。

**副产品,现在只记不用**:`previewFrame` 是一张按专辑 ID **精确定位**的 3840² 官方静态图,比第 3 节那条"按歌名在缓存里匹配"的高清替代更权威;`bgColor` / `textColor1` 是 Apple 给这张封面的官方配色,可以用来校准第 4 节自算的均值色。两者都已经落进缓存(`motion_preview_url` / collector 侧的 `bg_color`、`text_color`),但目前没有任何消费方。

## 设置项

| 设置页位置 | 键 | 改什么行为 |
|---|---|---|
| 灵动岛歌词 → 风格 | `np:notchCardStyle` | 选「跟随封面」(.coverArt,**默认值**)时灵动岛背景铺模糊封面,缺图退回深色渐变;其余三档固定填充,不碰封面 |
| 桌面悬浮歌词 → 配色 → 跟随封面取色 | `np:followsCoverArt`(默认关) | 开:悬浮歌词文字色改用 artworkAccentColor、灵动岛整套 tint 改用 notchAccentColor;关:悬浮歌词用手选前景色、灵动岛纯白。是配色卡里唯一跨展示方式生效的开关 |
| 桌面悬浮歌词 → 文字描边(开关+颜色) | `np:textStrokeEnabled` / `np:textStrokeColorHex` | 不属于封面功能,但 artworkAccentColor 的计算判据依赖它们(对比描边 vs 保证够亮),改描边连带重算悬浮歌词那份动态色 |

| 通用 → 封面 → 动态封面 | `np:motionCoverEnabled`(默认**开**) | 有 Apple Music 动态封面的专辑,让**歌词窗口**那张封面卡动起来;关掉一律静态。⚠️ 2026-09-10 起**只管歌词窗口**,灵动岛那份已撤(见第 6 节)。它只是总闸,之上还有低电量模式与 `reduceMotion` 两道 |

歌词窗口背景、封面卡、灵动岛封面小图的**静态**部分均无开关,有图就用;会不会动由上表最后一行那个开关管。

## 与其它功能的交互

- **歌词缓存(collector enrich cache)**:高清替代的 `cover_url` 是 collector 解析歌词时顺手写进 `lyrimuse-enrich-cache.json` 的——歌词解析成功与否直接决定有没有高清替代可用;「歌词管理」删除某条缓存也会连带让那首歌失去高清封面来源。
- **播放器选择(PlaybackPlayerPreference)**:取图的 bundleID 核对按当前选定播放器;系统 Now Playing 焦点被别的 App(网页视频等)抢走时不取图。停播/焦点丢失走 `clearIfWasPlaying()` 把封面连曲目一起清,歌词窗口回到「没有在播放」占位。
- **「最近播放」列表**:`EnrichCacheReader.coverURL` 同一套三级查找也给它当 Last.fm 缺图时的兜底(共享 coverByArtistTitle 索引);`ImageMemoryCache` 也是同一个,但按用途分两档(2026-08-20 性能审计):列表/头像走缩略档(解码期就降采样到 ≤256px,单张 ≤256KB——原来按原图存,一张网易云原生大图能吃掉 48MB 预算大半、把几百张列表小图挤出去,滚动时反复闪占位符),高清封面替代走原图档;失效 URL 有 10 分钟负缓存,不再每次视图重建都重发真实网络请求。
- **「跟随封面取色」与描边设置**:见上表,accentAgainstStroke 让封面功能反向依赖描边配置——这是有意的。
- **设置页预览**:两段都是编辑台、画的都是真视图(`LyricsOverlayView` / `NotchLyricsView`),所以 artworkAccentColor、封面小图、封面模糊背景在预览里跟真窗口逐像素同源。
- **换歌/停播状态机**:取图的触发、丢弃、清理全部锚定 `LocalPlaybackSource.lastKey` 的生命周期(见 01 章播放状态机);`clearIfWasPlaying` 里 lastKey 必须清,否则封面和歌词列表恢复播放后回不来。

## 数据与文件

- **读**:`~/.config/lyrimuse/lyrimuse-enrich-cache.json`(collector 维护,本 App 只读;`cover_url` 字段,2026-09-09 起还有 `motion_cover_url` / `motion_preview_url` / `motion_cover_checked`;按 mtime 缓存解析结果)。
- **子进程**:app bundle 内置的 `Contents/Resources/media-control/bin/media-control get --now`(不带 `--no-artwork`),10s 超时;每次换歌 1~4 次 + 3 秒后二次确认 1 次。
- **网络**:高清替代会下载(cover_url,网易云/Apple/QQ 图床);走 `URLSession.shared` → `URLCache.shared`(AppDelegate 调大到内存 32MB/磁盘 256MB),字节缓存落在系统默认 URLCache 磁盘位置。**动态封面另有三次请求**(2026-09-09,每张专辑一次性:master m3u8 → variant m3u8 → 那个单文件 mp4,实测 960² 档 7.17 MB);下好之后就是纯本地循环、零持续网络。collector 侧发现动态封面时会抓一次专辑页(约 330 KB / 专辑,结果落盘所以每张只抓一次)。
- **内存**:`ImageMemoryCache`(解码后 NSImage,400 张 / 48MB 双上限)。
- **写**:`~/.config/lyrimuse/motion-covers/<sha>.mp4`(2026-09-09,动态封面的本地副本;临时文件 + 原子改名,LRU 上限 400 MB,一份约 5～7 MB)。除此之外**不写文件** —— 静态封面的原始字节只活在内存(`artworkData` @Published)。collector 侧另有一份 `~/.config/lyrimuse/lyrimuse-motion-cover-cache.json`(专辑 ID → master/preview/配色,含"查过了但这张没有"的 `checked` 标记)。两份都是纯派生数据,删掉即重来。
- **UserDefaults**:`np:motionCoverEnabled`(2026-09-09,动态封面总闸,默认开)是本链路唯一的专属键;其余相关键(notchCardStyle / followsCoverArt / textStroke*)归属灵动岛与悬浮歌词外观。
- **进程边界**:取图和取状态是两条独立的 media-control 调用;collector(Go 进程)负责写 cover_url,本链路只消费。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 换歌触发取图 + 不清旧图的权衡 | `lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift` · `apply()` 的 `if trackChanged` 段 |
| 动态封面:发现 | `lyrimuse-collector/motioncover.go` — `motionCoverFor` / `parseMotionCover` / `findVideoArtwork`(专辑归属校验)/ `loadMotionCoverCache`;专辑 ID 两条来路 `applecatalog.go` · `appleCatalogAlbumIDFor` 与 `motioncover.go` · `motionCoverAlbumIDFromAppleURL`;写入点 `enrich.go` · `enrichEntry.fillMotionCover` 与字段 `MotionCoverURL` / `MotionPreviewURL` / `MotionCoverChecked`;单测 `motioncover_test.go` |
| 动态封面:**图像校验**(安全底座) | `lyrimuse-collector/motioncover.go` — `motionCoverMatchesCover` / `motionCoverPreviewSizedURL`;指纹与阈值复用 `coverquality.go` · `coverFingerprint` / `coverFingerprintDistance` / `coverFingerprintMaxDistance` |
| 动态封面:清单推导(纯函数) | `lyrimuse/Sources/LyrimuseCore/Local/MotionCoverManifest.swift` — `parseVariants` / `pick` / `mediaFileName` / `absolute` / `attribute`;selftest 在 `CoverArtTests.swift`「动态封面」 |
| 动态封面:下载与落盘 | `lyrimuse/Sources/lyrimuse/MotionCoverStore.swift` — `prepare` / `download` / `store` / `pruneIfNeeded`;缓存目录 `LyrimusePaths.configFile("motion-covers")` |
| 动态封面:播放与省电(唯一落点=歌词窗口封面卡) | `lyrimuse/Sources/lyrimuse/UI/MotionCoverLayer.swift` — `MotionCoverView` / `MotionCoverNSView`(`AVPlayerLooper`、离窗即释放);总闸在 `PlaybackCoordinator.refreshMotionCover` 与 `@Published motionCoverFile`;两个消费面的镜像字段 `WindowPlayback.motionCoverFile` / `NotchPlayback.motionCoverFile` |
| 动态封面:缓存读取 | `lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift` — `albumMatchedMotionCover`、字段 `motionCoverURL` / `motionPreviewURL` |
| 取图重试/载荷校验/二次确认 | 同上 · `fetchArtworkForCurrentTrack(expectedKey:)`、`artworkRetryDelays`、`artworkConfirmDelay`、`artworkKeyMatches` |
| 3 秒陈旧兜底 | 同上 · `scheduleArtworkStaleTimeout(forKey:)`、`artworkStaleTimeout` |
| 停播清理 | 同上 · `clearIfWasPlaying()` |
| 均值色计算 | 同上 · `computeAverageHex(from:)` / `computeAverageHex(cgImage:)`(CIAreaAverage) |
| 亮度规则三件套 | 同上 · `brightenedAccent`、`accentForDarkBackdrop`、`accentAgainstStroke`(+`relativeLuminance`/`contrastRatio`/`blendToLuminance`) |
| media-control 取图 | `lyrimuse/Sources/LyrimuseCore/Local/MediaControlClient.swift` · `fetchArtwork(player:)`、`ArtworkPayload`、`artworkBundleIDMatches` |
| 载荷 trackKey 推导 | `lyrimuse/Sources/LyrimuseCore/Local/MediaControlSnapshot.swift` · `trackKey(artist:title:)` |
| 解码收敛/高清替代/两条色管线 | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` · `artworkImage`、`highResArtworkImage`、`highResAverageHex`、`refreshHighResCover()`、`lowResArtworkThreshold`、`pixelSize(of:)`、`start()` 里 CombineLatest 订阅、`displayForegroundColor` |
| 高清替代触发判定(纯函数,selftest 覆盖) | `lyrimuse/Sources/LyrimuseCore/Local/CoverArtReplacementGate.swift` · `reason(width:height:lowResThreshold:)`、`isCoverShaped(width:height:)`、`accepts(candidateWidth:candidateHeight:systemWidth:reason:)`、`maxAspectSkew`(= collector `deviceArtworkMaxAspectSkew`) |
| 播放器没报专辑时封面解析用的专辑名(Apple 目录回填,只进挑选过程) | `lyrimuse-collector/albumhint.go` · `coverAlbumForTrack()`、`appleAlbumHintSync()`、`coverAlbumCorroboration()`、`coverNeedsHintCheck()`;`lyrimuse-collector/enrich.go` · `peripheralBackfillWindowOpen()`、`resolveTrackEnrichment()` 里的 `coverAlbum` |
| Spotify 原生原图档替代 | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` · `refreshSpotifyOriginalCover(_:)`、`spotifyCoverAppliedURL`;地址来源 `LyrimuseCore/Local/LocalPlaybackSource.swift` · `spotifyArtworkURL` / `noteSpotifyArtwork(url:forKey:)`;图床识别与换档 `LyrimuseCore/Local/SpotifyArtworkURL.swift` |
| 高清替代 URL 查找 | `lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift` · `albumMatchedCoverURL(artist:title:album:)`(当前播放专用,不退到忽略专辑那级)、`coverURL(artist:title:album:)`(「最近播放」/待机页用,多一级忽略专辑兜底)、`nativeSizedCoverURL(_:)`、`coverByArtistTitle()` |
| 借来的封面归属分档(device 可借归属 / qq 只借图)+ 自愈触发 | `lyrimuse-collector/enrich.go` · `siblingAlbumCover()`、`siblingCoverLocked()`、`coverSourceLendsAlbumIdentity()`、`hasAlbumVerifiedSiblingCover()`、`coverCanUpgradeToVerifiedSibling()`;存量假戳清洗 `lyrimuse-collector/coverstampmigrate.go` · `migrateBorrowedCoverAlbums()`(测试见 `coveralbum_test.go`) |
| collector 端封面选源(网易云/Apple/QQ 三源择优 + 同专辑邻居兜底 + 自愈重查) | `lyrimuse-collector/enrich.go` · `resolveTrackEnrichment()`、`preferAppleCoverOverNetease()`、`coverNeedsAlbumCheck()`、`coverSwapAllowed()`、`siblingAlbumCover()`;`lyrimuse-collector/match.go` · `albumScore()`;一次性纠正用 `collector recheck-cover [-apply] "歌手\|歌名\|专辑"`(见 `covercli.go`) |
| 灵动岛小图 / 背景 / tint | `lyrimuse/Sources/lyrimuse/UI/NotchLyricsView.swift` · `artworkThumbnail(_:)`、`backgroundLayer(size:)`、`accentOrWhite` |
| 小封面预先重采样(防摩尔纹) | `lyrimuse/Sources/LyrimuseCore/Util/ArtworkThumbnail.swift` · `squareBitmap(from:pixelSide:)`(纯函数,selftest `cover-art` 组);`lyrimuse/Sources/lyrimuse/UI/ArtworkThumbnailCache.swift` · `bitmap(for:pixelSide:)`;消费点 `NotchLyricsView.artworkThumbnail`、`MenuBarPanel.coverView`、`LastfmStatsSection.LiveScrobbleRow` |
| 歌词窗口背景 / 封面卡 / 配色切换 | `lyrimuse/Sources/lyrimuse/UI/LyricsWindowView.swift` · `artworkBackground`、`artworkCard`、`hasArtworkBackground`、`primaryTextColor` |
| 图片内存缓存 | `lyrimuse/Sources/lyrimuse/UI/CachedImage.swift` · `ImageMemoryCache`(`load`/`prewarm`)、`CachedImage` |
| 设置项 | `lyrimuse/Sources/lyrimuse/Settings/AppSettings.swift` · `notchCardStyle`、`followsCoverArt`;`lyrimuse/Sources/lyrimuse/SettingsView.swift` · `notchOverlayCard`;`lyrimuse/Sources/lyrimuse/UI/OverlayStyleSettingsRows.swift` · `OverlayColorSettingsRows` |

## 设计决策与已知坑

1. **换歌不立即清旧封面**:清空造成的整窗白闪比旧图多挂 200~500ms 糟得多;新图到货/确认无图才收敛,配 3 秒陈旧兜底防子进程挂死(`apply()` trackChanged 段注释,2026-08-05 用户反馈反转 08-02 的决定)。
2. **陈旧兜底必须随重试重排**:只按 sleep 之和(2.1s)论证落在 3s 内是错的——4 次 attempt 各要 fork 子进程+读几百 KB base64,平均往返超 ~225ms 兜底就会在重试没跑完时先开火,重演白屏(`artworkRetryDelays` 注释)。
3. **载荷 trackKey 比对大小写不敏感**:media-control 对同一首歌报过大小写不一致的元数据("2 Bad"/"Scream" 在 enrich 缓存踩过),严格比对会把自己的封面误判成别人的、永远占位(`artworkKeyMatches` 注释)。
4. **高清替代只在 ≤300px、或系统那份不是方形时才替**(第二条 2026-09-08 加,见第 15 条):系统那份才是「正在播的这一项」的权威;缓存是按元数据匹配出来的,同名不同版本可能错图。系统没给图时也不替——该显示占位音符(`refreshHighResCover` 注释)。
5. **refreshHighResCover 的 300ms debounce 是避 willSet 时机不是节流**:@Published 订阅回调跑在值未落库那一刻,读 self 其它属性可能拿到上一首的值,本项目为这个时机踩过两次坑;函数体还要再从数据源重读快照(`start()` 里 CombineLatest4 注释)。
6. **scaledToFill 之后必须钉 frame 再 clipShape**:三版才找对根因,「看起来圆」其实是模糊柔化骗了肉眼,像素级采样证明底层裁剪还是直角(`backgroundLayer` 注释)。
7. **动画触发键的双轨**:原始字节 Data 按字节比较(保持解码缓存引入前的判定语义),高清替代按指针比较(每次到货都是新实例)——两个 `.animation` 并排挂,少一个就有一种更新是硬切。
8. **均值色 2026-08-17 起是原始值,提亮下放到消费面**:灵动岛(永远深底)要「够亮」,悬浮歌词(背景未知)要「跟描边够对比」——在源头统一提亮等于替桌面那侧做错误决定;近黑兜底两边策略也不同(灵动岛丢亮度换固定浅灰,悬浮歌词保亮度只丢色相)(`artworkAverageHex` / `accentAgainstStroke` 注释,08-16 近黑浅灰配白描边看不清的回归)。
9. **网易云图床 param 只降不升**:`?param=600y600` 拿 800 原图只给 600,`param=1200y1200` 也不上采样;去 param 只对 `*.music.126.net` 做,其它图源参数可能编码着尺寸段,去掉可能 404(`nativeSizedCoverURL` 注释)。
10. **灵动岛小图缺图不画占位**:播放中绝大多数曲目拿得到封面,为少数情况长期锁一块空方块不值;配合「旧图留到新图到货」,布局跳动只发生在启动第一首和真没封面两种情况(`artworkThumbnail` 注释)。
11. **高清替代绝不能退到「忽略专辑」的兜底**(2026-08-26 用户报的方大同「放不过自己」实锤):同一首歌在不同专辑版本下封面经常真的不一样。原来 `refreshHighResCover` 复用的是给「最近播放」列表设计的 `coverURL`,那个函数专门给 scrobble 专辑名不可信的场景多退一级「忽略专辑,按歌手+歌名」的索引——两条同名不同专辑的缓存记录一旦命中这级,选哪条全看 Dictionary 遍历顺序,而且还会被 `onlyIfMissing: true`(见下一条)焊死到换歌之前。修法:拆出 `albumMatchedCoverURL`,只保留认专辑的两级查找,当前播放这个消费面专辑名来自系统 Now Playing、必然可信,没有退这一步的必要。
12. **collector 端「宽松包含」的 albumScore=100 不等于真的对上版**:`coverNeedsAlbumCheck`/`resolveTrackEnrichment` 原来用 `albumScore(...) == 0` 判「这张封面不属于当前专辑,该问别的源」,但 `albumScore` 的 100 分档本来就是「候选是目标的子串」(重发版/豪华版这类带后缀的专辑名天然命中),不是真对上版。方大同「很不低调」「烦」的本地专辑是《JTW 西游记 (Gold) [Explicit]》,网易云/Apple 曲库里都还是没有这个后缀的旧版《JTW西游记》——被判成「宽松包含、对上了」,QQ 音乐（这两首实际收录了新版封面的那个源）永远没机会被问到。2026-08-26 把门槛从 `== 0` 收严成 `< 200`(200 = 逐字相等/仅大小写繁简差异),让"同名不同版"也触发向 QQ 补问一次;`qqCoverFallback` 内部本就按 `albumScore` 自行避开精选集/合辑,给出结果就值得信,`coverSwapAllowed` 相应放行 QQ 那档跨源替换(不再要求 `fresh.CoverAlbum` 打分——QQ 从不回传专辑名)。发现即修:`collector recheck-cover -apply` 手动补跑一次这四首。
13. **文字打分核不出「封面图本身对不对」,同专辑邻居比自己单独检索更可信**:2026-08-27 同一张专辑接着报的方大同「Once」「All Night」——QQ 音乐搜索索引对这两首歌各自只收录了一条记录,专辑名文本上一样"对得上"《JTW 西游记 (Gold) [Explicit]》,挂的封面却是另一款《2CD [B+G]》合集版(半黑半金站姿),跟同专辑其它曲目实际的单张《Gold》版封面(纯金底半脸特写)是完全不同的两张图——`albumScore` 只能核对文字,这类"文字对上、图不对"的情况天生核不出来,不管门槛怎么调都堵不住。加了 `siblingAlbumCover`:三源各自检索都给不出精确对版结果(`< 200`)时,最后问一次缓存里同专辑(同歌手、逐字同专辑名)已经有 `CoverSource=="qq"` 定案的邻居,直接借它的封面——只借 qq 那档,不借网易云/Apple(那两档自己也可能只是"宽松包含"的 100 分,借了等于把一份信不过的答案传染给另一首歌)。

    ⚠️ **借用一度把「未认领归属」伪造成「已核实」,2026-09-07 修**(用户报 Michael Jackson
    《Michael》里「Hold My Hand (with Akon)」封面不对:列表显示的是 QQ 的
    《The Ultimate Collection》白底金色剪影,而 Last.fm 给那条 scrobble 的自带图其实是对的
    《Michael》正封)。链路:QQ 那一档**从不回传专辑名**,所以 `qqCoverFallback` 选中的图刻意
    把 `cover_album` 清空(图有用、但不认领归属);可 `siblingAlbumCover` 把这张图借给同专辑
    其它曲目时,调用方盖上了 `cover_album = album` —— 一次借用把"未认领"升级成"逐字对上"
    (albumScore 200)。两层后果:App 侧 `localAlbumVerifiedCovers` 是唯一有资格**越过 Last.fm
    自带图**的一档、判据正是这个字段(见 12 章「第①级自带图的第二道纠正」),错图因此顶掉了
    对图;collector 侧 `coverNeedsAlbumCheck` 撞上 200 分直接放行,这条记录从此**永远不会**
    再被复查。本机实测被这样盖过章的有 **385 条**(缓存 4068 条的 9.5%)。

    修法**不是取消借用**(那会把这一条的收益一起丢掉),而是让借用如实报告归属 ——
    `siblingAlbumCover` 现在分两档、并回传第三个返回值 `albumVerified`:
    ①`device` 邻居(归属由"设备当时确实在播这首歌"这个事实保证,不是文字匹配;还要求邻居
    **自己那条记录**的 `cover_album` 已经逐字对上)→ 可以连归属一起借走,调用方照旧盖章;
    ②`qq` 邻居(原有行为、原有收益)→ **不再**盖 `cover_album`,跟 `qqCoverFallback` 同口径,
    于是它在 App 侧退回普通 `localCovers`(只在 Last.fm 没有自带图时兜底)。netease/apple
    仍然不借,理由同上一段。顺带把邻居扫描**定序**(原来吃 Go map 的随机迭代顺序,同专辑有
    两条可借邻居时每次启动可能借到不同的图,表现是"封面偶尔自己变了"且复现不出来)。

    配套两件:①`coverCanUpgradeToVerifiedSibling` 让"归属没核实、但同专辑有 device 邻居可借"
    的条目在下次被播到时重解析一次(判据刻意收窄成"真有邻居可借"——放宽成"qq 档就重查"的话,
    QQ 正常给对图的那一大类会每条白重试满 5 次,正是 `coverNeedsAlbumCheck` 当初收窄要避开的
    成本);`coverSwapAllowed` 相应加一档放行"借来的 device 封面"(它不带 `NeteaseURL`,
    旧判据会把它永远拦在缓存外)。②一次性迁移 `migrateBorrowedCoverAlbums`
    (`coverstampmigrate.go`)擦掉存量假戳,幂等、只碰 `cover_album` 一个字段;实测启动时
    清了 385/4068 条。**故意不顺手换封面**:换了 `cover_url` 就得重算 `accent_color`(要联网
    取图),而"封面四件套一起判、不出现新封面配旧主色"是既有纪律 —— 换图交给上面那条自愈路径,
    擦戳本身已经让用户看得见的症状消失(归属不再作假,Last.fm 的对图立刻赢回来)。
    实测那 385 条里 79 条同专辑有 device 邻居可借、122 条只有 netease/apple 已核实邻居、
    185 条一个可借邻居都没有;后两类靠"不再盖章"就已经回到正确行为。

    ⚠️⚠️ **这次修复自己踩了一个死锁,记在这里**:自愈判据那个"同专辑有没有可借邻居"的探针
    第一版自己 `enrichMu.Lock()`,而它的调用链是 `trackEnrichment → needsPeripheralBackfill →
    探针` —— `trackEnrichment` **从进函数就一直持着 enrichMu**(它里面那句"enrichMu 此刻已持有,
    普通 map 即可"就是证据),Go 的 `sync.Mutex` 不可重入,于是当场自锁。表现极具迷惑性:
    collector **进程还活着**、别的 goroutine(api 汇总、artwork relay)照常打日志,只有轮询、
    feed 刷新、歌曲解析无声停摆 —— 装机 11 分钟后靠 `lyrimuse-lastfm-recent-feed.json` 的
    mtime 不再前进才发现(那个文件 15~60s 一刷,是判 collector 死活最便宜的探针)。修法是把
    探针改成 `hasAlbumVerifiedSiblingCoverLocked`(不自己加锁、名字带 Locked 声明约定),并在
    `needsPeripheralBackfill` 头注写明"必须在持有 enrichMu 的前提下调用"。**给这个文件里任何
    在 `trackEnrichment` 临界区内被调到的判据加东西时,先问一句它会不会碰锁。**

14. **设备直送封面不再无条件顶掉远程候选:判「是不是同一张图」,不判「谁更大」**(2026-09-02,用户报《24K Magic》「封面这么糊清晰度很低」)。形态很干净 —— **同一张专辑的其它 8 首都是 800×800,只有标题曲拿到了一张 120×120**(`cover_source=device`,本地 7 KB 的 `file://`)。歌词窗口那张大卡在 Retina 下要画到 ~560px,120px 放大 4.7 倍就是那个糊。全库扫下来 113 条 device 条目里有 **21 条**低于 300px(120px×10、150px×11),其余 92 条不受影响。

    成因是两条**各自都对**的设计叠在一起:① `deviceArtworkMinEdge = 64` 下限故意压得极低,注释里写明「Arc/Edge 播 Apple Music 网页版时 MediaSession 实际上送的封面就是 120x120,收紧到 200 就是在挡真实数据」;② 设备封面**无条件顶掉**网易云/Apple/QQ/同专辑邻居那一整套结果,而 `coverSwapAllowed` 又规定 `cover_source == "device"` 一律不再换源 —— 于是那张 120px **永久锁死**,连上一条的 `siblingAlbumCover` 明明已经在缓存里找到了 800×800 也照样被盖掉。

    ⚠️ **不能改成"分辨率不够就不用设备封面"** —— 那会把上一条(第 13 条)和 8-31 的 Immortal 案例**反过来**:那些案例里设备给的 120×120 是**对的**,QQ 那张高清图是**挂错的**。单看分辨率选,等于每次都把对的换成错的。

    所以判据是**"两张图是不是同一张"**:设备封面的价值在**身份**(这一刻这个 App 自己吐出来的,不靠文字匹配去猜),远程候选的价值在**分辨率**;两者其实是同一张图时就拿高清那份,不是同一张就身份优先、认这个糊。判据表与实现见 `lyrimuse-collector/coverquality.go` 头注。三个实现细节值得记:

    - **"候选有多大"必须从 URL 读(`coverURLIntendedEdge`),不能量解码结果**:`loadCoverImage` 是给取色用的、**返回的远程图已经降采样**(网易云 64y64、QQ 300),拿它的尺寸判清晰度会把一张 800×800 读成 64px,判据恒成立、修复一次都不会触发。实现时真踩了这一脚。
    - **指纹必须箱式取平均、不能取最近邻**:8×8 aHash 对高分辨率图只采 64 个点的话,同一张图的 120px 版和 800px 版会采到完全不同的内容。实测坐实:箱式平均下用户那张 120px 与同专辑邻居 800px(被降到 64px)的指纹**逐位相同**、距离 0。
    - **阈值是拿真实数据校准的**:正例距离 0,反例(缓存里随机抽的 8 张其它专辑封面)17…39,无一误判;阈值取 10,落在 0↔17 的空隙里,离两边分别 10 和 7。
    - **存量自愈通路是 `coverSwapAllowed` 的 device 分支**(不是新造 CLI):那 21 条各自下次被播到、走到 `backfillPeripheralFields` 的外围自愈时自动升级,用户不需要做任何事;要立刻修某几首用 `collector recheck-cover -apply`(它走同一个判定)。

15. **高清替代的第二个触发条件:系统那份「不是封面的形状」也替,形状容差跟 collector 对齐**(2026-09-08,用户报 YouTube Music 的 MV 条目「封面是视频的第一帧,而不是正经的封面」)。现场数据:王子《Why You Wanna Treat Me So Bad?》是 MV 类型条目,Safari 经 MediaSession 上报的 artwork 是 **320×180 的 TIFF 视频缩略图**(Prince 抱吉他的舞台镜头);下一首歌曲类型条目《Sexy Dancer》给的是 544×544 方形真封面——所以这是 YT Music 对 MV 条目的平台行为,不是偶发。

    根因是**两端口径不一致**:collector 的 `deviceartwork.go` 从 8-31 起就有 15% 的长宽比容差(`deviceArtworkMaxAspectSkew`),这张图偏离 44% 被拒收、回退 Apple 目录取封面,所以网页显示的是真封面;App 侧 `refreshHighResCover` 只有一个判据「宽 ≤ 300 才找替代」,320 刚好越过门槛被当成「够大的正经封面」原样显示,再被展示面的 `scaledToFill` 裁成方块——用户看到的就是视频画面中间一截。

    修法不是调 300 这个数(调成 320,下一个 640×360 的缩略图照样漏),而是把「像不像一张封面」的形状判据补到 App 侧、容差**逐字复用** collector 的 15%,判定拆成纯函数 `CoverArtReplacementGate`(LyrimuseCore,selftest 直接断言;PlaybackCoordinator 在 App target 里自测进程碰不到)。三个细节:

    - **形状先于尺寸判**:1280×720 的视频帧再大也不是封面,不能因为「够宽」就放过。
    - **下载回来后的接受判据按理由分**:太小那条维持「替代图要比系统那份宽」;形状那条只要求替代图自己是方形——换的是形状不是分辨率,若沿用「比系统那份宽」的门槛,1280×720 的视频帧会把 600×600 的真封面挡在外面。
    - **第一次播某个 MV、缓存还没解析出封面时,仍先显示视频帧**:跟原来「先小图后变清晰」一致,等 collector 写入缓存后由 `enrichContentVersion` 补查路自动纠正;没有替代来源时视频帧至少还是「这一项自己的图」,比占位音符信息量大。

    通用性:任何播放器上报非方形封面都走这条(视频网站 16:9 缩略图、竖屏短视频、横幅 banner);正经封面自带的小幅不规则(带留白边框)落在 15% 之内不受影响。

16. **播放器没报专辑名时,collector 选封面按 Apple 目录回填的专辑名打分 —— 但回填名只进挑选过程,绝不落盘成 `cover_album`**(2026-09-08 晚,用户报王子《Why You Wanna Treat Me So Bad?》MV「用的是这个专辑封面?不应该是另外一个吗」:显示的是 1993 年合集《The Hits/The B-Sides》的图,歌属于 1979 年的《Prince》)。**链路**:MV 条目 `album=""`,缓存 key `王子|Why You Wanna Treat Me So Bad?|`;首次解析(08:31Z)时歌手名还是「王子」、网易云没匹配到,封面退到 Apple 全文搜索 —— 对这个歌名 Apple 第一条就是合集版、原版排第二(当天重放同一条搜索顺序仍如此),`searchAppleMusicMatch` 没有专辑证据只能取 titleFallback;之后所有能纠正封面的机制(`preferAppleCoverOverNetease` / QQ 复查 / 同专辑邻居 / `coverSwapAllowed` 跨源替换 / `coverNeedsAlbumCheck`)在 `album == ""` 时**全部直接跳过**,歌词后来经「Prince」别名重配成功、网易云链接也补上了,封面却冻在合集那张。同一天早上加的专辑名回填(02 章决策 27)算出的专辑是《Prince》,但它按设计只进呈现 / 上送,于是出现「专辑名《Prince》、封面合集」的错位;当天下午的决策 15 让 App 不再显示视频帧、改显示这张缓存封面,把错位暴露到了 App 上。

    **修法**:`coverAlbumForTrack`(albumhint.go)—— 播放器报了专辑就是它,没报就用回填名;`resolveTrackEnrichment` 里这一步**同步**等 Apple(`appleAlbumHintSync`,后台那次还在飞就等它、最多 8 秒;这些调用方本来就在 goroutine 里等九个歌词源),旁证 = 缓存里已有的 + 这一轮 MusicBrainz 统一名 + 这一轮歌词胜出候选报的署名(`coverAlbumCorroboration`;王子那首靠 kugou 候选报的「Prince」认下 Apple 的《Prince》)。coverAlbum 进:Apple 匹配打分(`appleMusicMatchCached`,顺带让 `apple_music_url` 指向原版专辑)、网易云 vs Apple 对版、QQ 与同专辑邻居两道 guard、外围补全与 `recheck-cover` 的 `coverSwapAllowed`。存量自愈:`coverNeedsHintCheck` —— 专辑为空、回填名与现有 netease / apple 封面的 `cover_album` **完全不沾边**(`albumScore == 0`,刻意不用 `coverNeedsAlbumCheck` 那条 `< 200`:回填是猜的名、来源报的是真名,写法差异不值得白重试 5 轮)才触发一次外围补全,受同一套 5 次上限 + 10 分钟节流(`peripheralBackfillWindowOpen`,从 `needsPeripheralBackfill` 尾部拆出、行为不变)。本机存量:专辑为空的条目只有 7 条(6 条有封面:4 netease、2 apple),已过 5 次上限的王子那条用 `collector recheck-cover -apply` 一次性纠正。

    **三条边界**(跟第 13 条 09-07 那个 bug 的修法对齐):① `trackEnrichment` 从取 `enrichMu` 到放锁之间**不许**调任何会加锁的函数 —— `coverAlbumForTrack` 内部经 `lyricResolvedArtists` 取同一把锁,所以在 `trackEnrichment` / `backfillPeripheralFields` 里都在取锁**之前**算好;② 写 `e.CoverAlbum` 的几处一律不写 coverAlbum:Apple / 网易云那两档写来源自己报的专辑名(安全),同专辑邻居借用与 device 那两处继续写真实入参 `album`(没报就写空)—— 「没人报过专辑名 = 不认领归属」这条语义保住,`cover_album` 作为 App 侧越过 Last.fm 自带图、collector 侧不再复查的唯一凭据不被猜出来的名字污染;③ 复查抖动按 ② 的口径收窄到 `albumScore == 0`。**通用性**:任何播放器没报专辑的条目(MV、单曲、网页播放器)都走这条,报了专辑的条目一行行为不变。

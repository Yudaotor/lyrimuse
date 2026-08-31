# 03. 封面链路
> 最后核对:2026-08-17 · 基线:2a2bf8b+工作树

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
- **门槛**(`lowResArtworkThreshold = 300`):用 CGImageSource 只读图头取系统封面的像素宽(`pixelWidth(of:)`,不解码整图)。只有 `0 < 宽 < 300` 才找替代——系统没给封面(宽 0)时该显示占位音符,不该悄悄换成缓存匹配出来的另一张图;正常给大图的播放器(Apple Music)一次都不会触发。300 的依据:封面卡 920px / 300px 已是 3 倍放大。
- **替代图来源**:`EnrichCacheReader.albumMatchedCoverURL(artist:title:album:)`,读 collector 解析歌词时顺手记下的 `cover_url`(网易云/Apple/QQ),两级查找:归一化 key 精确命中 → looseMatch(忽略空格/大小写/繁简,但仍然认专辑)。**不**退到「歌手|歌名」忽略专辑的那级索引——系统这份的专辑名来自 Now Playing、就是当前真正在播的这一版,退一步反而是拿错版本的风险(2026-08-26 用户报的方大同「放不过自己」实锤:缓存里同名不同专辑的两条记录封面完全不同,退到忽略专辑那级会随机凑到错的那条;`coverURL(artist:title:album:)` 保留三级查找给「最近播放」/待机页那两个专辑名本就不一定可信的消费方用,见 `EnrichCacheReader.swift` 两个函数各自的注释)。再经 `nativeSizedCoverURL` 处理:**只对网易云图床**(`*.music.126.net`)去掉 `?param=600y600`——那个参数只降不升(实测原生 800×800 带 param 拿回 600×600,`param=1200y1200` 也不上采样),去掉才拿得到原图;别的图源参数未核实,不动。
- **换歌时立刻撤掉上一首的高清图**(和均值色同进退)再异步下载——留着的话新图下载完之前会显示上一首的封面,比「先小图后变清晰」糟得多。
- **下载**走 `ImageMemoryCache.shared.load(url, variant: .original)`(同 URL 并发只发一次请求;底层 URLSession.shared 吃 URLCache 磁盘缓存;原图档——这张要给 920pt@2x 的封面卡,不能吃缩略降采样)。回来后三道守卫:任务未取消、`LocalPlaybackSource.shared.title` 还是发起时那首、**拿回来的宽度必须大于系统那份**(缓存里可能存着一张同样小的图,不值得换)。
- **均值色同步给**:`highResAverageHex` 用 `LocalPlaybackSource.computeAverageHex(cgImage:)` 后台算,跟图一起赋值。有高清图时两条强调色管线**必须**按它算——系统那份可能是灰底占位图,界面实际显示的是高清替代,强调色还按占位图算就是一团无关的灰。
- 替代关系是「只替不动权威」:系统那份才是「正在播的这一项」的权威图,缓存那张是按歌手/歌名/专辑**匹配**出来的,同名不同版本可能是另一张封面,所以只在系统那份确实太小时才替。

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

### 5. 四个图像消费面

所有图像消费面读的都是 `poller.highResArtworkImage ?? poller.artworkImage`——**解码收敛在 PlaybackCoordinator**:`artworkData` 变化时 `NSImage(data:)` 只解一次(`artworkImage`),灵动岛一个 body 里两处读封面不会把同一张几百 KB 的 JPEG 每次重算 body 都解两遍。

1. **灵动岛封面小图**(`NotchLyricsView.artworkThumbnail`):歌词行尾端(卡片右下角),边长 `max(16, min(32, 行高-12))` = 32pt,圆角 5pt + 极淡白描边 + 小投影(给磨砂玻璃风格下的浅色封面兜轮廓)。没有封面数据**整个不占位**(不画空方块)——换歌时旧图留到新图到货,只有「启动后第一首」和「这首歌真没封面」才发生一次宽度增减。这枚小图无开关(2026-08-10 删掉「显示专辑封面」开关,固定有图就显示)。
2. **灵动岛「跟随封面」背景**(`NotchLyricsView.backgroundLayer`):`notchCardStyle == .coverArt` 且有图时,封面 scaledToFill + blur 20 + 45% 黑,底下先铺一层不透明的 darkGradient 打底(blur 会把图像边缘羽化成半透明,没有打底卡片四周会透出桌面)。模糊半径 20 远小于歌词窗口的 72——灵动岛 4.7:1 又矮又宽,照搬大半径会把任何封面抹成统一深灰。没图(或风格不是 coverArt)退回所选固定风格的填充。
3. **歌词窗口动画背景**(`LyricsWindowView.artworkBackground`):AM 式「暗底+lighten 光斑+慢旋转」,图层预烘焙(`bakeWindowBackgroundLayers`:暗底 + 3 张分区取色羽化光斑,seed 确定性),视图层仅 GPU 变换动画 + 0.15 遮罩——细节与四轮校准史见 07-lyrics-window.md。
4. **歌词窗口封面卡**(`LyricsWindowView.artworkCard`):左栏 1:1 方图(Color.clear 撑框 + scaledToFill),最大 460pt;没图画灰底 music.note 占位。卡片实际宽度回写 `artworkWidth`,整排播放控制按钮按它缩放。0.5s 交叉淡入动画收在 overlay 内容上而不是卡片最外层(挂外层会把同事务里的布局位移一起 animate 成「进度条从上面飘下来」)。

**共同细节**:换图动画的触发键有两个——原始字节 `poller.artworkData`(Data 按字节比较,保持跟加解码缓存之前逐字节相同的判定语义;`artworkImage` 是 NSObject,== 退化成指针比较,语义不等价)和 `poller.highResArtworkImage`(这里指针比较反而是对的:每次到货都是新解码的实例)。灵动岛背景和小图的 `.scaledToFill()` 之后、`.clipShape` 之前必须显式钉一次 `.frame(width:height:)`——scaledToFill 会向布局系统请求比可见区更大的 frame,clipShape 按紧邻上一个 View 的 frame 算圆角,不钉的话圆角落在偏大矩形的边缘,可见区域实际是直角(像素级采样验证过,肉眼会被模糊骗)。

**文字配色联动**:歌词窗口 `hasArtworkBackground = poller.artworkData != nil`——只看系统那份、不看高清替代(高清替代只在系统有图且太小时才存在,所以两者有图性一致)。它为 true 时全窗文字切固定浅色系(.white 系),false 时用系统 .primary/.secondary;空状态占位(ContentUnavailableView vs 自绘白色版)、进度条/按钮的 rim 色、封面卡投影深浅也都随它切。

## 设置项

| 设置页位置 | 键 | 改什么行为 |
|---|---|---|
| 灵动岛歌词 → 风格 | `np:notchCardStyle` | 选「跟随封面」(.coverArt,**默认值**)时灵动岛背景铺模糊封面,缺图退回深色渐变;其余三档固定填充,不碰封面 |
| 桌面悬浮歌词 → 配色 → 跟随封面取色 | `np:followsCoverArt`(默认关) | 开:悬浮歌词文字色改用 artworkAccentColor、灵动岛整套 tint 改用 notchAccentColor;关:悬浮歌词用手选前景色、灵动岛纯白。是配色卡里唯一跨展示方式生效的开关 |
| 桌面悬浮歌词 → 文字描边(开关+颜色) | `np:textStrokeEnabled` / `np:textStrokeColorHex` | 不属于封面功能,但 artworkAccentColor 的计算判据依赖它们(对比描边 vs 保证够亮),改描边连带重算悬浮歌词那份动态色 |

歌词窗口背景、封面卡、灵动岛封面小图均无开关,有图就用。

## 与其它功能的交互

- **歌词缓存(collector enrich cache)**:高清替代的 `cover_url` 是 collector 解析歌词时顺手写进 `lyrimuse-enrich-cache.json` 的——歌词解析成功与否直接决定有没有高清替代可用;「歌词管理」删除某条缓存也会连带让那首歌失去高清封面来源。
- **播放器选择(PlaybackPlayerPreference)**:取图的 bundleID 核对按当前选定播放器;系统 Now Playing 焦点被别的 App(网页视频等)抢走时不取图。停播/焦点丢失走 `clearIfWasPlaying()` 把封面连曲目一起清,歌词窗口回到「没有在播放」占位。
- **「最近播放」列表**:`EnrichCacheReader.coverURL` 同一套三级查找也给它当 Last.fm 缺图时的兜底(共享 coverByArtistTitle 索引);`ImageMemoryCache` 也是同一个,但按用途分两档(2026-08-20 性能审计):列表/头像走缩略档(解码期就降采样到 ≤256px,单张 ≤256KB——原来按原图存,一张网易云原生大图能吃掉 48MB 预算大半、把几百张列表小图挤出去,滚动时反复闪占位符),高清封面替代走原图档;失效 URL 有 10 分钟负缓存,不再每次视图重建都重发真实网络请求。
- **「跟随封面取色」与描边设置**:见上表,accentAgainstStroke 让封面功能反向依赖描边配置——这是有意的。
- **设置页预览**:两段都是编辑台、画的都是真视图(`LyricsOverlayView` / `NotchLyricsView`),所以 artworkAccentColor、封面小图、封面模糊背景在预览里跟真窗口逐像素同源。
- **换歌/停播状态机**:取图的触发、丢弃、清理全部锚定 `LocalPlaybackSource.lastKey` 的生命周期(见 01 章播放状态机);`clearIfWasPlaying` 里 lastKey 必须清,否则封面和歌词列表恢复播放后回不来。

## 数据与文件

- **读**:`~/.config/lyrimuse/lyrimuse-enrich-cache.json`(collector 维护,本 App 只读;`cover_url` 字段;按 mtime 缓存解析结果)。
- **子进程**:app bundle 内置的 `Contents/Resources/media-control/bin/media-control get --now`(不带 `--no-artwork`),10s 超时;每次换歌 1~4 次 + 3 秒后二次确认 1 次。
- **网络**:仅高清替代会下载(cover_url,网易云/Apple/QQ 图床);走 `URLSession.shared` → `URLCache.shared`(AppDelegate 调大到内存 32MB/磁盘 256MB),字节缓存落在系统默认 URLCache 磁盘位置。
- **内存**:`ImageMemoryCache`(解码后 NSImage,400 张 / 48MB 双上限)。
- **不写任何文件**;封面原始字节只活在内存(`artworkData` @Published)。
- **UserDefaults**:本功能自身无专属键;相关键(notchCardStyle / followsCoverArt / textStroke*)归属灵动岛与悬浮歌词外观。
- **进程边界**:取图和取状态是两条独立的 media-control 调用;collector(Go 进程)负责写 cover_url,本链路只消费。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 换歌触发取图 + 不清旧图的权衡 | `lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift` · `apply()` 的 `if trackChanged` 段 |
| 取图重试/载荷校验/二次确认 | 同上 · `fetchArtworkForCurrentTrack(expectedKey:)`、`artworkRetryDelays`、`artworkConfirmDelay`、`artworkKeyMatches` |
| 3 秒陈旧兜底 | 同上 · `scheduleArtworkStaleTimeout(forKey:)`、`artworkStaleTimeout` |
| 停播清理 | 同上 · `clearIfWasPlaying()` |
| 均值色计算 | 同上 · `computeAverageHex(from:)` / `computeAverageHex(cgImage:)`(CIAreaAverage) |
| 亮度规则三件套 | 同上 · `brightenedAccent`、`accentForDarkBackdrop`、`accentAgainstStroke`(+`relativeLuminance`/`contrastRatio`/`blendToLuminance`) |
| media-control 取图 | `lyrimuse/Sources/LyrimuseCore/Local/MediaControlClient.swift` · `fetchArtwork(player:)`、`ArtworkPayload`、`artworkBundleIDMatches` |
| 载荷 trackKey 推导 | `lyrimuse/Sources/LyrimuseCore/Local/MediaControlSnapshot.swift` · `trackKey(artist:title:)` |
| 解码收敛/高清替代/两条色管线 | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` · `artworkImage`、`highResArtworkImage`、`highResAverageHex`、`refreshHighResCover()`、`lowResArtworkThreshold`、`pixelWidth(of:)`、`start()` 里 CombineLatest 订阅、`displayForegroundColor` |
| 高清替代 URL 查找 | `lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift` · `albumMatchedCoverURL(artist:title:album:)`(当前播放专用,不退到忽略专辑那级)、`coverURL(artist:title:album:)`(「最近播放」/待机页用,多一级忽略专辑兜底)、`nativeSizedCoverURL(_:)`、`coverByArtistTitle()` |
| collector 端封面选源(网易云/Apple/QQ 三源择优 + 同专辑邻居兜底 + 自愈重查) | `lyrimuse-collector/enrich.go` · `resolveTrackEnrichment()`、`preferAppleCoverOverNetease()`、`coverNeedsAlbumCheck()`、`coverSwapAllowed()`、`siblingAlbumCover()`;`lyrimuse-collector/match.go` · `albumScore()`;一次性纠正用 `collector recheck-cover [-apply] "歌手\|歌名\|专辑"`(见 `covercli.go`) |
| 灵动岛小图 / 背景 / tint | `lyrimuse/Sources/lyrimuse/UI/NotchLyricsView.swift` · `artworkThumbnail(_:)`、`backgroundLayer(size:)`、`accentOrWhite` |
| 歌词窗口背景 / 封面卡 / 配色切换 | `lyrimuse/Sources/lyrimuse/UI/LyricsWindowView.swift` · `artworkBackground`、`artworkCard`、`hasArtworkBackground`、`primaryTextColor` |
| 图片内存缓存 | `lyrimuse/Sources/lyrimuse/UI/CachedImage.swift` · `ImageMemoryCache`(`load`/`prewarm`)、`CachedImage` |
| 设置项 | `lyrimuse/Sources/lyrimuse/Settings/AppSettings.swift` · `notchCardStyle`、`followsCoverArt`;`lyrimuse/Sources/lyrimuse/SettingsView.swift` · `notchOverlayCard`;`lyrimuse/Sources/lyrimuse/UI/OverlayStyleSettingsRows.swift` · `OverlayColorSettingsRows` |

## 设计决策与已知坑

1. **换歌不立即清旧封面**:清空造成的整窗白闪比旧图多挂 200~500ms 糟得多;新图到货/确认无图才收敛,配 3 秒陈旧兜底防子进程挂死(`apply()` trackChanged 段注释,2026-08-05 用户反馈反转 08-02 的决定)。
2. **陈旧兜底必须随重试重排**:只按 sleep 之和(2.1s)论证落在 3s 内是错的——4 次 attempt 各要 fork 子进程+读几百 KB base64,平均往返超 ~225ms 兜底就会在重试没跑完时先开火,重演白屏(`artworkRetryDelays` 注释)。
3. **载荷 trackKey 比对大小写不敏感**:media-control 对同一首歌报过大小写不一致的元数据("2 Bad"/"Scream" 在 enrich 缓存踩过),严格比对会把自己的封面误判成别人的、永远占位(`artworkKeyMatches` 注释)。
4. **高清替代只在 <300px 才替**:系统那份才是「正在播的这一项」的权威;缓存是按元数据匹配出来的,同名不同版本可能错图。系统没给图时也不替——该显示占位音符(`refreshHighResCover` 注释)。
5. **refreshHighResCover 的 300ms debounce 是避 willSet 时机不是节流**:@Published 订阅回调跑在值未落库那一刻,读 self 其它属性可能拿到上一首的值,本项目为这个时机踩过两次坑;函数体还要再从数据源重读快照(`start()` 里 CombineLatest4 注释)。
6. **scaledToFill 之后必须钉 frame 再 clipShape**:三版才找对根因,「看起来圆」其实是模糊柔化骗了肉眼,像素级采样证明底层裁剪还是直角(`backgroundLayer` 注释)。
7. **动画触发键的双轨**:原始字节 Data 按字节比较(保持解码缓存引入前的判定语义),高清替代按指针比较(每次到货都是新实例)——两个 `.animation` 并排挂,少一个就有一种更新是硬切。
8. **均值色 2026-08-17 起是原始值,提亮下放到消费面**:灵动岛(永远深底)要「够亮」,悬浮歌词(背景未知)要「跟描边够对比」——在源头统一提亮等于替桌面那侧做错误决定;近黑兜底两边策略也不同(灵动岛丢亮度换固定浅灰,悬浮歌词保亮度只丢色相)(`artworkAverageHex` / `accentAgainstStroke` 注释,08-16 近黑浅灰配白描边看不清的回归)。
9. **网易云图床 param 只降不升**:`?param=600y600` 拿 800 原图只给 600,`param=1200y1200` 也不上采样;去 param 只对 `*.music.126.net` 做,其它图源参数可能编码着尺寸段,去掉可能 404(`nativeSizedCoverURL` 注释)。
10. **灵动岛小图缺图不画占位**:播放中绝大多数曲目拿得到封面,为少数情况长期锁一块空方块不值;配合「旧图留到新图到货」,布局跳动只发生在启动第一首和真没封面两种情况(`artworkThumbnail` 注释)。
11. **高清替代绝不能退到「忽略专辑」的兜底**(2026-08-26 用户报的方大同「放不过自己」实锤):同一首歌在不同专辑版本下封面经常真的不一样。原来 `refreshHighResCover` 复用的是给「最近播放」列表设计的 `coverURL`,那个函数专门给 scrobble 专辑名不可信的场景多退一级「忽略专辑,按歌手+歌名」的索引——两条同名不同专辑的缓存记录一旦命中这级,选哪条全看 Dictionary 遍历顺序,而且还会被 `onlyIfMissing: true`(见下一条)焊死到换歌之前。修法:拆出 `albumMatchedCoverURL`,只保留认专辑的两级查找,当前播放这个消费面专辑名来自系统 Now Playing、必然可信,没有退这一步的必要。
12. **collector 端「宽松包含」的 albumScore=100 不等于真的对上版**:`coverNeedsAlbumCheck`/`resolveTrackEnrichment` 原来用 `albumScore(...) == 0` 判「这张封面不属于当前专辑,该问别的源」,但 `albumScore` 的 100 分档本来就是「候选是目标的子串」(重发版/豪华版这类带后缀的专辑名天然命中),不是真对上版。方大同「很不低调」「烦」的本地专辑是《JTW 西游记 (Gold) [Explicit]》,网易云/Apple 曲库里都还是没有这个后缀的旧版《JTW西游记》——被判成「宽松包含、对上了」,QQ 音乐（这两首实际收录了新版封面的那个源）永远没机会被问到。2026-08-26 把门槛从 `== 0` 收严成 `< 200`(200 = 逐字相等/仅大小写繁简差异),让"同名不同版"也触发向 QQ 补问一次;`qqCoverFallback` 内部本就按 `albumScore` 自行避开精选集/合辑,给出结果就值得信,`coverSwapAllowed` 相应放行 QQ 那档跨源替换(不再要求 `fresh.CoverAlbum` 打分——QQ 从不回传专辑名)。发现即修:`collector recheck-cover -apply` 手动补跑一次这四首。
13. **文字打分核不出「封面图本身对不对」,同专辑邻居比自己单独检索更可信**:2026-08-27 同一张专辑接着报的方大同「Once」「All Night」——QQ 音乐搜索索引对这两首歌各自只收录了一条记录,专辑名文本上一样"对得上"《JTW 西游记 (Gold) [Explicit]》,挂的封面却是另一款《2CD [B+G]》合集版(半黑半金站姿),跟同专辑其它曲目实际的单张《Gold》版封面(纯金底半脸特写)是完全不同的两张图——`albumScore` 只能核对文字,这类"文字对上、图不对"的情况天生核不出来,不管门槛怎么调都堵不住。加了 `siblingAlbumCover`:三源各自检索都给不出精确对版结果(`< 200`)时,最后问一次缓存里同专辑(同歌手、逐字同专辑名)已经有 `CoverSource=="qq"` 定案的邻居,直接借它的封面——只借 qq 那档,不借网易云/Apple(那两档自己也可能只是"宽松包含"的 100 分,借了等于把一份信不过的答案传染给另一首歌)。

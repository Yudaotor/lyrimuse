v1.5.0

The lyrics matching algorithm was overhauled — concert recordings should
stop getting studio lyrics, and vice versa. YouTube Music and Spotify
playing in a browser are now properly supported as players, and the UI
speaks Traditional Chinese now. Worth knowing before you upgrade: first
launch re-scores your library in a throttled background pass, so some
tracks will switch to a better match over the following hours (a new
"follow algorithm upgrades" toggle lets you freeze picks instead); the
player setting is now multi-select (your old choice carries over); the
notch's auto-hide switches are now separate from the desktop overlay's;
and Intel Macs get in-app auto-update from this version on — but v1.5.0
itself needs one last manual install.

歌词匹配算法做了一轮大修——演唱会现场歌曲不该再拿到录音室歌词，反过来也一样；
网页版 YouTube Music 和 Spotify 也正式当播放器支持了；界面新增繁体中文。升级
前值得知道：首次启动会在后台节流地给全库重新打分，接下来几个小时里会有一些歌
换上更对的歌词（新增「自动跟进算法升级」开关，不想被后台换的可以关掉）；播放
器设置改成多选（原单选值自动带过来）；灵动岛的自动隐藏开关跟悬浮歌词拆开了；
Intel 从本版起有 App 内自动更新——但 v1.5.0 本身还得手动安装最后一次。

New / 新功能
- Select several players at once instead of one
  播放器支持多选
- YouTube Music and Spotify in a browser are properly supported as
  players — in whichever browser you pick; lyrics sync precisely to the
  page's own progress, with a one-click self-test
  正式支持网页版 YouTube Music 和 Spotify 当播放器，浏览器可自选：歌词按页面
  自己的进度精确同步，可一键自检
- YouTube Music (LyricFind) and Kuwo join as lyrics sources — eight in
  total now
  新增 YouTube Music（LyricFind）和酷我两个歌词源，总数达到八个
- The UI is available in Traditional Chinese, as a third interface
  language alongside Simplified Chinese and English
  界面新增繁體中文，与简体中文、英文并列的第三种界面语言
- Cantonese songs get word-aware Jyutping readings; all four romanization
  languages now default to on
  粤语歌自动标注粤拼（按词消歧）；罗马音语言开关四项默认全开
- Hand-picked lyrics can be locked against automatic rematching (new
  toggle, applied retroactively)
  手动选定的歌词可以锁定，不再被自动匹配换掉（新开关，可追溯生效）
- Background lyric upgrades can be turned off entirely — settled picks
  then stay put until you re-search yourself
  新增「自动跟进算法升级」开关：关掉后已选定的歌词不再被后台换掉
- A first-time lyrics search can be stopped — the song settles as "no
  lyrics" instead of searching forever
  首次联网搜歌词可以「停止搜索」，停止后落定为「暂无歌词」，不再一直转
- Six new global hotkeys, with conflict detection and on-screen feedback
  六个新全局快捷键（歌词搜索、翻译、读音、灵动岛歌词、菜单栏歌词、偏移归零），
  带冲突检测和屏幕反馈
- The notch's expanded view is composable: track-info header, playback
  controls, next-line preview, lyric-offset control and per-row cover art
  are all toggleable
  灵动岛展开区可自由拼装：曲目信息头部、播放控制键、下一句预览、歌词微调、行
  尾封面都能开关
- The notch's top row is configurable too: each ear picks its module
  (title / artist / album / cover / controls / elapsed / remaining /
  none), the equalizer can be turned off or moved to either ear (and was
  redrawn), lyrics can be hidden entirely, pause-collapse is optional,
  and the minimum width is much lower
  灵动岛顶行也能拼：左右耳各自八选一（歌名/歌手/专辑/封面/播放控制/已播时长/
  剩余时长/不显示），音浪可关、可换边（样式也重画了），「显示歌词」可整个关
  掉，「暂停缩回」可选，最小宽度大幅放宽
- The notch animates in and out — pausing shrinks the card back into the
  notch instead of it vanishing — and gained its own lyrics alignment
  setting
  灵动岛有了出/收场动画（暂停时整卡缩回刘海，不再瞬间消失），并新增自己的
  歌词对齐方式
- The overlay, menu bar and notch settings pages are all editors now,
  with live preview and reset-to-defaults; menu-bar lyrics gained an
  alignment mode; a one-time tip shows that ⌘-dragging moves the icon
  悬浮歌词、菜单栏、灵动岛的设置页都改成带实时预览的编辑台，可一键恢复默认；
  菜单栏歌词新增对齐方式；首次启动提示 ⌘ 拖拽可挪图标
- Menu bar: a progress icon next to the lyrics (fills bottom-up with
  playback, Kugou-style), playback controls on hover, and adjustable
  lyric font weight and size
  菜单栏：歌词旁新增进度图标（随播放进度自下而上染色，仿酷狗）、悬停显示播放
  控制三键、歌词字重和字号可调
- Desktop overlay: a hover control row (expand to lyrics window /
  settings / close), a ⚙ quick-settings menu with a standalone
  lyric-search mini window, an unlock button right on the overlay, and an
  alignment setting; the control capsule is smaller and uses a
  liquid-glass look (macOS 26+)
  悬浮歌词新增悬停控制排（展开到歌词窗口/设置/关闭）、⚙ 快捷设置菜单和独立的
  「搜索歌词…」小窗、锁定后可在悬浮窗上直接解锁，还有对齐方式设置；控制胶囊
  整体缩小、换液态玻璃材质（macOS 26+）
- Desktop overlay: stroke color presets (white text + black stroke, black
  text + white stroke), with black text + white stroke + follow-cover as
  the new default look, and the settings preview now replicates the real
  word-by-word karaoke fill
  桌面悬浮歌词：新增描边配色预设（白字黑边、黑字白边），黑字白边+跟随封面成为
  新默认外观，设置页预览条现在会真实重放逐字卡拉OK填色
- Duet lyrics show a speaker indicator, so you can see who's singing
  对唱歌词显示声部指示（圆点+细竖线），一眼看出谁在唱
- The lyrics window's right pane is now Play History, replacing the play
  queue: day-grouped records with paging — or your local pending listens
  when Last.fm isn't connected
  歌词窗口右栏改成「播放记录」（取代播放队列）：按天分组、可翻页；未连
  Last.fm 时显示本地待提交的收听
- The Lyrics Manager gained sorting (11 orderings), an offset column,
  album search, a placeholder row while a song is being searched,
  candidate covers in the decision panel, and round labels on multi-round
  searches
  歌词管理新增排序（11 种）、「偏移」列、按专辑搜索、搜索中的歌也有占位行；
  决策面板显示候选封面；搜索进度标注轮次
- Settings shows lyrics-library stats, with translations split into
  source-provided vs machine-translated
  设置新增歌词库统计面板，译文按「源自带 / 机翻」分开统计
- The lyrics search shows each source's availability and failure reason,
  and Settings gained a one-click lyric-source test
  联网搜索能看到各歌词源的可用情况和失败原因；设置页新增歌词源一键测试
- The Dock icon has a right-click menu (Settings / Lyrics Manager /
  Lyrics Window / Last.fm), the lyrics window's title bar gained a
  settings button, and the "no lyrics" / "network failed" empty states
  offer a Search Lyrics button right there
  Dock 图标有了右键菜单（设置/歌词管理/歌词窗口/Last.fm）；歌词窗口标题栏加
  了设置按钮；「暂无歌词」「网络连接失败」两个空态页直接给出「搜索歌词…」按钮
- The About page was redesigned — live GitHub star count, usage and
  copyright notes, and a third-party licenses list
  关于页重新设计：显示仓库实时 star 数，新增「使用与版权说明」和「第三方许可」
- Every outbound network request is audit-logged, and the diagnostics
  export got much richer
  所有外发网络请求有审计日志；诊断导出的内容大幅扩充
- In-app auto-update now covers Intel Macs
  App 内自动更新对 Intel 生效
- The player picker is an icon grid; trusted players show their real icons
  播放器选择改成图标网格；信任列表显示各 App 真实图标

Lyrics matching & scoring / 歌词匹配与打分
- Different concerts of the same song are now told apart
  同一首歌的不同场演唱会能分开了
- QQ Music can find live-album tracks now
  QQ 音乐搜得到现场专辑曲目了
- QQ lyrics carry their official translation, romanization and Japanese
  furigana tracks now
  QQ 源歌词现在能带上官方译文、罗马音和日语假名标注
- Album names glued across scripts ("The One演唱会") tokenize correctly,
  and an album named 演唱会/现场/音乐会 counts as a live version
  中英文粘写的专辑名（「The One演唱会」）能正确分词；专辑名带「演唱会/现场/
  音乐会」的按现场版对待
- Variants with the right duration on the right album no longer lose over
  a version tag; NetEase picks anchor on duration + album, with the
  album's track list as a search fallback
  时长和专辑都对的变体不再因版本限定词落选；网易云按时长+专辑锚定，搜索不到
  时用专辑曲目单兜底
- "DJ remix" versions riding the original artist's name are no longer
  accepted as the original
  顶着原唱歌手名的「DJ 某某版」混音不再被当成原版收下
- Chinese-catalog matching got a batch of fixes: traditional/simplified
  artist spellings, bracketed aliases, Cantonese vs Mandarin versions of
  a song, mixed-script artist names, and variant Han characters (one
  variant glyph used to make every Chinese source miss the song)
  中文曲库匹配一批修正：繁简艺名、括号别名、同一首歌的粤语/国语版、中英混排
  艺名、汉字异体字（原来一个异体字就能让三家中文源全搜不到）现在都能对上
- Kugou candidates are ranked across the whole result page
  酷狗候选改成整页排序
- When a lyric's two timing tracks contradict each other, the bad one is
  dropped or repaired instead of trusted
  一份歌词的行级/逐字两套时间轴互相矛盾时，坏的那套会被弃用或修复，不再照单
  全收
- Word-timing bonuses no longer overrule a better title match; romanized
  stage names ("Khalil Fong") no longer get correct Chinese lyrics
  rejected as the wrong language
  逐字时间轴加分不再压过更对的标题吻合；罗马化艺名歌手的中文歌词不再被误判成
  「语言对不上」
- When no source has synced lyrics, plain-text lyrics are adopted
  automatically as a fallback
  全部源都只有纯文本歌词时会自动采纳兜底，不再必须手动采纳
- Blocked sources retry through the system proxy, and a failing source
  cools down on its own instead of slowing every search
  歌词源被网络屏蔽时自动经系统代理兜底；单个源故障会按原因自行冷却，不再拖慢
  整轮搜索
- NetEase lyrics no longer show literal \' artifacts
  网易云歌词不再出现字面的 \'

Last.fm & scrobbling / Last.fm 与打卡
- Paging through listening history is fast now
  翻听歌历史快了
- "On this day" reports failures and offers a retry instead of a blank
  page; the tab became "Footprint" — a local listening-footprint card
  plus a smarter look-back that widens to the whole week when the exact
  day is empty
  「那年今日」失败时不再空白，可重试；该段升级为「足迹」——本地收听足迹卡 +
  更会找料的「那年今日」（当天没记录会放宽到那一周）
- Ads on YouTube Music / Spotify web no longer enter the listening
  history
  YouTube Music / Spotify 网页版的广告不再混进收听历史
- Covers verified by your own library take precedence over Last.fm's
  wrongly matched art
  本机已核实的封面优先于 Last.fm 配错的图
- Failed scrobbles are no longer silently lost — they're logged locally
  and can be backfilled, and a backfill batch isn't permanently
  quarantined by one rate limit
  打卡失败不再默默丢失——本地留痕、可回填补交；回填批次不再因一次限流被永久
  隔离
- Play counts merge alternate spellings of the same song or artist
  (Chinese/English titles, traditional/simplified, romanized names)
  across stats, charts and digest notifications
  播放次数会合并同一首歌/同一歌手的不同写法（中英文歌名、繁简体、罗马字），
  统计、榜单和日报/周报推送同口径
- Scrobbles submit exactly what the player reported; multi-artist
  credits can go out as-is, first-artist-only, or via a smart mode that
  follows Last.fm's own catalog; scrobbling is now documented
  (docs/scrobbling.md)
  打卡按播放器上报的信息原样提交；合唱署名可选原样、只发第一位，或按 Last.fm
  自己的编目判断的智能档；打卡机制有了公开文档（docs/scrobbling.md）

Fixes / 修复
- Now-playing covers got a batch of accuracy fixes: artwork sent by the
  player itself is used first, wrong-edition album art is corrected, and
  Apple covers doubled in resolution
  正在播放的封面一批对版修复：优先用播放器自己送来的封面、同名不同版专辑不再
  配错图、Apple 封面分辨率翻倍；网页展示页遇到设备直送封面不再空白
- Searching lyric candidates dropped from minutes to seconds in the worst
  case
  「搜索候选歌词」最坏情况从两三分钟降到几秒
- NetEase rate limiting is handled properly now — exponential backoff, a
  steadier endpoint, and no more false "rate limited" labels on sources
  that simply had no match
  网易云限流治理：指数退避、换更稳的端点；「没给出候选」不再被误标成限流
- AMLL's embedded translations were never actually read; machine
  translation no longer skips repeated chorus lines
  AMLL 自带的译文此前一直没被读取，已修；机翻不再漏掉重复的副歌行
- Translation or romanization lines no longer vanish over whitespace
  variants
  翻译/罗马音不再因空格种类差异整行消失
- The LRC [offset:] tag now works end to end, including the web page
  LRC 的 [offset:] 标签全链路生效（含网页端）
- The overlay's playback buttons register clicks where they're drawn
  悬浮歌词的播放控制按钮点哪儿是哪儿（命中区不再偏移）
- Notch lyrics stay readable on bright covers
  灵动岛跟随封面时，亮色封面下歌词也看得清
- Adopting a search result from the lyrics window no longer permanently
  freezes that song's lyrics
  从歌词窗口采纳歌词不再被悄悄永久冻结
- Rematch shows its actual outcome instead of a generic "no conclusion"
  重新匹配能显示具体结论了
- The Lyrics Manager highlight follows track changes; its filter bar no
  longer reflows on selection
  歌词管理高亮行跟随切歌；筛选栏选中时不再跳动
- The menu-bar panel opens over fullscreen apps and dismisses on Space
  change
  菜单栏面板在全屏 App 上能弹出，切换空间自动收起
- Platform promo lines and credit/staff lines are filtered out of lyrics
  歌词里的平台宣传行和署名/职员表行会被过滤
- Lyrics-window polish: background tinting no longer over-saturates
  near-black covers, and the volume capsule doesn't linger after playback
  stops
  歌词窗口：纯黑封面的背景不再渲染得过艳；停播后音量胶囊不再残留
- The Settings window keeps a fixed title; windows are listed in the
  Window menu; Dock reopen only auto-opens lyrics when nothing else is open
  设置窗口标题固定；窗口注册进「窗口」菜单；Dock 重开仅在没有其它窗口时弹歌词
- Importing an iCloud backup actually downloads it and validates it first
  iCloud 导入备份会真的触发下载，并先校验文件
- The "now scrobbling" count no longer goes stale, and "Nth listen" no
  longer shows a frozen old count for songs you haven't played in a while
  「正在记录」计数不再和实际播放次数脱节；久未听的老歌再听时「第 N 次听」不再
  显示冻结的旧次数

Ops / 运维
- The release pipeline validates the update feed at tag time
  发布流水线在打 tag 时校验更新源结构
- build.sh installs atomically, so concurrent builds can't corrupt the app
  build.sh 改成原子安装，并发构建不再弄坏已装的 App
- The collector reports the app's own version, so Settings can no longer
  show two mismatched version numbers
  采集服务版本号与 App 同源，设置页不再出现两个对不上的版本号

## Download / 下载

| Chip / 芯片 | dmg | zip |
|---|---|---|
| **Apple Silicon** (M1 and later, recommended) / **Apple M 系列**（推荐） | [Lyrimuse-v1.5.0-macos.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos.dmg) | [Lyrimuse-v1.5.0-macos.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos.zip) |
| **Intel** / **Intel 芯片**（也能在 Apple Silicon 上跑，但体积更大、没必要） | [Lyrimuse-v1.5.0-macos-intel.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos-intel.dmg) | [Lyrimuse-v1.5.0-macos-intel.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos-intel.zip) |

Not sure which one? Check your chip under **About This Mac**.
不确定该下哪个？打开「关于本机」看芯片是 Apple M… 还是 Intel Core…

26 commits since v1.4.0.

**Full Changelog**: https://github.com/Yudaotor/lyrimuse/compare/v1.4.0...v1.5.0

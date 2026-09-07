v1.6.0

Spotify lyric sync got a precision overhaul — the constant slight
drift after resuming, the backwards jump when pausing, and the lag
after ads are all gone. The menu bar can now show two lyric lines
(next line, translation or romanization under the current one — the
Dynamic Island has the same option), Migu Music joins as the ninth
lyrics source, you can choose when a play scrobbles to Last.fm, and
the settings pages went through a full reorganization with trimmed
copy. Worth knowing before you upgrade: the matching algorithm is
stricter about Cantonese-vs-Mandarin versions, so a throttled
background pass may switch a few tracks to a better match over the
following hours (the "follow algorithm upgrades" toggle freezes picks
if you prefer); appearance settings you never touched now use
recalibrated defaults, so a few surfaces may look slightly different;
and the old global karaoke switch became three per-surface toggles
(your previous choice carries over).

Spotify 歌词同步做了一轮精度大修——恢复播放后恒偏快一点、一按暂停歌词倒退、
广告后整首偏慢，这些全修掉了。菜单栏歌词支持双排显示（当前句下面再排一行
下一句/译文/罗马音，灵动岛也有同一套副行）；新增咪咕音乐，歌词源达到九个；
Last.fm 什么时候记一次播放现在由你定；设置页整体重排、文案全面精简。升级前
值得知道：匹配算法对粤语/国语版本更严格了，后台会节流地重查一部分歌、接下
来几个小时里可能有歌换上更对的词（不想被换就关「自动跟进算法升级」）；你从
没动过的外观设置项会换上重新校准的默认值，个别界面观感可能略有变化；原来
全局的「卡拉OK染色」开关拆成了三个展示面各自的「卡拉OK效果」（原选择自动
迁移）。

New / 新功能
- The menu bar can show a second lyric row — next line, translation or
  romanization under the current line; the Dynamic Island capsule has
  the same option
  菜单栏歌词支持双排：当前句下面再排一行下一句、译文或罗马音；灵动岛胶囊
  也有同一套副行
- Migu Music joins as a lyrics source — nine in total now
  新增咪咕音乐歌词源，总数达到九个
- Choose when a play counts for Last.fm: the official 50% rule, 75%,
  90%, or only when the track plays to the end; ListenBrainz is
  unaffected
  Last.fm「Scrobble 时机」可选：官方规则（50%）、75%、90% 或播完才记；
  ListenBrainz 不受影响
- Player linkage is per-player now: pick which players launch with
  Lyrimuse, which ones launch Lyrimuse, and optionally quit Lyrimuse
  once the players it follows have all quit
  播放器联动改为逐播放器勾选：打开 Lyrimuse 时拉起哪些播放器、哪些播放器
  打开时拉起 Lyrimuse，都单独可选；还新增「跟随播放器退出」
- An opt-in beta channel: turn on "Receive beta updates" in Settings →
  About to try pre-release builds; turn it off to stay on stable
  新增「接收测试版更新」开关（设置 → 关于）：打开即可收到测试版，关掉回
  正式版通道
- The notch's expanded header gains a quick-actions row: search lyrics,
  toggle lyrics, open settings, or close the island — one hover away
  灵动岛展开态新增「快捷操作」按钮排：搜索歌词、显示歌词、设置、关闭，
  hover 即达
- The notch's expanded state can be wider than the resting capsule —
  set both widths with one dual-slider; lyrics alignment gains an
  automatic option that follows duet parts
  灵动岛展开态可以比稳态更宽（双滑块一次设好两个宽度）；对齐方式新增
  「自动」档，按对唱声部分边
- When nothing is playing, the notch shows the app icon and blends into
  the real notch; hovering opens a compact idle panel with resume /
  open-player / settings shortcuts — and the desktop overlay shows a
  "♪ Lyrimuse" mark instead of nothing
  没有歌在放时，灵动岛画上 App 图标、与真刘海融为一体，hover 展开一块小小
  的空闲面板（继续播放/打开播放器/设置）；悬浮歌词也不再空无一物，显示
  「♪ Lyrimuse」品牌标记
- Lyrics Manager: retry every track still missing lyrics in one click
  (all of them, or just the filtered ones), and mark a track as
  instrumental yourself; tracks without lyrics are now classified in
  four tiers instead of a blanket red "no lyrics"
  歌词管理：没搜到词的歌可以一键全部重试（也可只重试筛选出的那些），还能
  手动「标为纯音乐」；无词条目改为四档分级，不再一律红色「无歌词」
- A storage-style lyrics library panel in Settings: total count, a
  proportion bar of word-synced / line-synced / plain / instrumental,
  translation and romanization tallies
  设置页新增「歌词库」统计面板：总数、逐字/逐行/纯文本/纯音乐比例条、
  译文与罗马音统计，读法照系统设置的储存空间
- The manual lyrics search window is resizable and draggable, each
  candidate shows title / artist / album on separate lines, candidates
  with identical text are labeled, and sources that couldn't be reached
  are reported separately (DNS / connection / server) instead of
  counting as "no result"
  「搜索候选歌词」窗口可拖动、可改大小；每条候选的歌名/歌手/专辑分行显示；
  文字相同的候选带标注；连不上的源单独归因（DNS/连接/服务器），不再和
  「没搜到」混为一谈
- Picking lyrics from the overlay's quick-search keeps the window open,
  so you can switch sources and listen until one sounds right
  悬浮歌词的快捷搜索小窗采纳候选后不再关窗——边听边换源，点即切
- Source priority is reordered by dragging now (arrows stay for
  keyboard and VoiceOver)
  歌词源「顺序优先」列表支持拖拽排序（上下箭头保留给键盘和 VoiceOver）
- Japanese lyrics typed with simplified-Chinese glyphs by some sources
  are repaired back to proper kanji — rule-based, no lookup table
  日文歌里被源写成简体字的日文汉字自动修回（纯通用规则，不维护人工表）

Improved / 改进
- Spotify position accuracy: anchors are pinned at stream-event arrival
  (±20ms), stale anchor republishes are recognized and ignored, pauses
  freeze at the pause instant, and a one-shot probe corrects the late
  anchor after ads
  Spotify 位置精度：锚点按事件到达时刻钉住（±20ms）、识别并忽略陈旧锚点
  重发、暂停冻结在暂停那一刻、广告后用一次性探针校正晚发的开播锚点
- Lyrics matching v15: Cantonese and Mandarin versions of the same song
  are inferred and judged across the whole candidate batch, so a
  correctly tagged "(粤语)" candidate no longer loses to the
  wrong-language one
  歌词匹配 v15：同曲的粤语/国语版本改为批级推断加双向判决，标着「(粤语)」
  的正确候选不再输给另一个语种的
- Matching also got stricter along the way: bare "(Edit)" cuts no
  longer masquerade as the original, translations baked into the lyric
  body are split out, and candidates are ranked by how well their
  reported duration fits the track
  匹配还顺带更严了：裸「(Edit)」剪辑版不再冒充原版、混进正文的翻译行会被
  拆出来、候选按上报时长与歌曲的吻合度排序
- Lyric sources you disabled are no longer queried at all
  关掉的歌词源不再发出任何请求
- All lyric sources share a system-DNS-first, DoH-fallback connection
  path — fixes six sources being unreachable under VPN-pushed DNS
  九个歌词源统一走「系统 DNS 优先、失败退 DoH」的连接路径——修好 VPN 下发
  DNS 时六个源整体连不上的问题
- The alias retry round re-queries only the sources that are missing
  usable candidates, instead of all-or-nothing
  歌手别名重查改为只补查缺候选的那几个源，不再「全无候选才救急」
- Default source order re-ranked by measured adoption; trailing credit
  lines no longer inflate a candidate's duration score, and 指导/总监/
  策划/导演 credit lines are filtered too
  默认歌词源顺序按实测采用率重排；尾部署名行不再虚增候选的时长评分，
  「指导/总监/策划/导演」类署名行也会被过滤
- Karaoke word-fill is a per-surface toggle now (overlay / island /
  menu bar); the Lyrics Window always renders word-by-word
  卡拉OK逐字填色改为悬浮歌词/灵动岛/菜单栏各自的开关；歌词窗口始终逐字
- Launch at login is a standard system login item now (visible in
  System Settings), and restarts run the app at proper UI priority —
  animations no longer risk being throttled
  开机启动改为系统登录项（系统设置里可见），重启后以正常 UI 优先级运行，
  动画不再有被降速的风险
- Settings copy was trimmed across the board — shorter titles, fewer
  lecturing subtitles, tighter help bubbles
  设置页文案全面精简——标题更短、副标题更少、气泡说明更克制
- A corrupted config file is never silently overwritten anymore: it's
  quarantined with a banner and an explicit recovery path, and
  background-service restarts now report their result in the settings
  window
  配置文件损坏不再被静默覆盖：改为隔离保留、横幅提示、明确的恢复出口；
  功能开关保存后，后台服务重启的结果也会显示在设置窗口里

Fixed / 修复
- The notch no longer expands when the pointer is merely below it
  灵动岛不再在光标只是移到卡片下方透明区时就展开
- Notch animations: collapsing no longer undershoots and crawls back,
  expanded content crossfades in place instead of sliding, and the
  equalizer bars no longer flicker during size changes
  灵动岛动画：收回不再先缩过头再爬回来，展开内容原地淡入淡出而不是平移，
  音浪条在卡片变形时不再闪跳
- The menu bar preview in Settings no longer flashes when the status
  item is rebuilt
  设置页的菜单栏预览不再在状态栏项重建时闪一下
- Play counts Last.fm was slow to index are re-probed with backoff
  instead of being stuck at "no count"; tapping a count shows exactly
  which spellings were merged into it
  Last.fm 迟迟没计入的播放次数会按退避重探，不再被永久钉成「没有」；点开
  次数还能看到它由哪些写法合并而来
- "Back to current track" in Lyrics Manager scrolls to the right row on
  the first click
  歌词管理的「回到当前播放」第一次点就滚到位
- The search sheet's source counter is derived from the source list
  itself — no more "0/8" next to "nine sources"
  搜索弹窗的源计数直接读源清单，不会再出现「0/8」旁边写着「九个源」

## Download / 下载

| Chip / 芯片 | dmg | zip |
|---|---|---|
| **Apple Silicon** (M1 and later, recommended) / **Apple M 系列**（推荐） | [Lyrimuse-v1.6.0-macos.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos.dmg) | [Lyrimuse-v1.6.0-macos.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos.zip) |
| **Intel** / **Intel 芯片**（也能在 Apple Silicon 上跑，但体积更大、没必要） | [Lyrimuse-v1.6.0-macos-intel.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos-intel.dmg) | [Lyrimuse-v1.6.0-macos-intel.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos-intel.zip) |

Not sure which one? Check your chip under **About This Mac**.
不确定该下哪个？打开「关于本机」看芯片是 Apple M… 还是 Intel Core…

46 commits since v1.5.0.

**Full Changelog**: https://github.com/Yudaotor/lyrimuse/compare/v1.5.0...v1.6.0

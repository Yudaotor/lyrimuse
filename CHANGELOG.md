# Changelog

Release notes for every published version, newest first. The same text is in
each version's git tag annotation and on its
[GitHub release page](https://github.com/Yudaotor/lyrimuse/releases).

发布日志，最新版在最上面。同一份正文也在对应 git tag 的注释里和
[GitHub Releases 页](https://github.com/Yudaotor/lyrimuse/releases)上。

<!--
  每节正文与对应 tag 注释**逐字一致**——这是 .github/scripts/check_release_tag.sh
  的第 5 条硬校验(正式版 tag),对不上就拒绝构建。v1.7.0 之前两边是各写各的,
  RELEASE_NOTES_v1.7.0.md 比 tag 正文多了一行「## Download / 下载」标题,谁也没发现。

  发版时不要手抄:写好本文件的新一节、提交,再用
      .github/scripts/changelog_section.sh v<版本> > <临时文件>
      git tag -a v<版本> <验证过的 commit> -F <临时文件>
  打 tag。节标题 `## v<版本>` 是抽取脚本的分节边界——正文里别写 `## v<数字>` 开头的行,
  别的 `##` 标题不影响。
  完整流程见 docs/releasing.md。
-->

## v1.8.0

New / 新功能
- Added Apple Music as an eleventh lyrics source — the only one carrying
  Apple's own word-by-word timing, and the only one that asks you to
  connect the account in Settings, once every six months
  新增第十一个歌词源 Apple Music——唯一带官方逐字歌词的源，也是唯一需要在设置里
  连账号的源，六个月连一次
- Added a full rescan that re-picks every lyric in the library under
  today's matching rules
  新增「全库重新挑选」，用现在的匹配规则把整个曲库的歌词重挑一遍
- A full rescan skips hand-corrected lyrics, confirmed instrumentals and
  tracks whose timeline you tuned
  全库重挑会跳过手动改过的歌词、确认过的纯音乐和自己校过时间轴的歌
- You can now import your own .ttf and .otf fonts for the lyrics
  现在可以导入自己的 .ttf / .otf 字体给歌词用
- Split the karaoke fill into two independent colours, one sung and one
  unsung
  卡拉OK的已唱和未唱拆成了两个独立颜色
- Added a thickness setting for the frosted background behind the desktop
  lyrics
  悬浮歌词的毛玻璃背景可以调厚薄了
- Added a switch for the playback buttons that appear when you hover the
  desktop lyrics
  鼠标移到悬浮歌词上会出现的那排播放键，可以关掉了
- You can now pick a font family for the menu bar lyrics
  菜单栏歌词可以自己选字体了
- Added the second line and font size to the menu bar quick settings panel
  菜单栏快捷设置面板补上了「副行」和「字号」
- The menu bar panel now offers one button that starts the music again when
  nothing is playing
  什么都没在放的时候，菜单栏面板给一颗能把歌放起来的键
- Added back and forward keys to the Settings window
  设置窗口加了「后退 / 前进」两颗键
- Replaced the system colour panel with a smaller picker of our own
  选颜色改用自己的小面板，不再打开系统取色器
- The menu bar preview now draws the max-width limit
  菜单栏预览里画出了最大宽度那条线
- AMLL now looks a track up by the ID the system provides, instead of
  relying on NetEase and QQ being switched on
  AMLL 改用系统给出的曲目 ID 直接查，不再依赖网易云和 QQ 开着
- New installs now scrobble collaborations with smart credit; existing
  installs keep their setting
  新安装的打卡默认走「智能合作署名」，老用户的设置不变

Improved / 改进
- Moved the score breakdown into the expanded row in the lyrics manager
  歌词管理的评分明细移进了展开行
- Opening the lyrics manager is faster on a large library
  曲库很大时，歌词管理打开得更快
- Reworked the selected state of the player cards: the card lifts off the
  page, and the accent colour stays on the border and the checkmark
  重做了播放器卡片的选中样式：卡片提亮浮起，蓝色只留在描边和对号上
- Lined up both toolbar rows in the editor stages, column by column
  编辑台的两行工具栏改成逐列对齐
- The background service no longer does work nothing asked for: no web
  accent colour without a relay, no ListenBrainz without a token
  后台服务不再做白工：没配网页中继就不算配色，没填 ListenBrainz 令牌就完全不跑
- Removed the "N/9" badge and the "thin evidence only" filter; the full
  count is on the track's decision sheet
  移除了「N/9」徽章和「仅证据薄」筛选，完整数字在这首歌的「解析决策」里看

Fixed / 修复
- Fixed Apple Music lyrics stopping when another app took over the
  system's now-playing slot
  修复别的 App 抢走系统「正在播放」后，Apple Music 歌词停住的问题
- Fixed the menu bar lyrics flickering, disappearing, and rebuilding in the
  middle of a line
  修复菜单栏歌词闪烁、消失、唱到一半重建的问题
- Fixed three ways per-word romanisation came out wrong, including a blank
  word eating a syllable
  修复逐字罗马音的三处错误，包括空白词吃掉一个音节
- Fixed Chinese being read as Japanese in lines that splice kana into a
  Chinese clause
  修复中日混排的行里，中文被按日语读音标注的问题
- Fixed DJ mix segments borrowing the studio version's lyrics
  修复 DJ Mix 片段套用录音室版本歌词的问题
- The search sheet now says why a track has no usable lyrics
  搜索弹窗现在会说明这首歌为什么没有可用歌词
- Fixed a music video's length being taken as the song's length
  修复把音乐视频的时长当成歌曲时长的问题
- Fixed catalog matching ignoring the artist, crossing storefronts, and
  settling for the first album track within tolerance
  修复目录匹配不核对歌手、跨地区、以及在容差内直接取第一个专辑版本的问题
- Fixed parenthesised name lists and the 组曲 prefix derailing the search
  修复括号里用斜杠分隔的名字串、以及「组曲」前缀把搜索带偏的问题
- Fixed the Dynamic Island's black bar not matching the real notch height
  修复灵动岛黑条高度跟真实刘海对不上的问题
- Fixed the equalizer's position when it has an ear to itself and when the
  island is expanded
  修复均衡器独占一只耳朵时、以及灵动岛展开时的位置
- Fixed the desktop lyrics control bar opening from outside the lyrics text
  修复悬浮歌词的控制条从歌词文字之外也会打开的问题
- Fixed a Dock icon staying around for minimized and auxiliary windows
  修复最小化窗口和辅助窗口占着 Dock 图标不放的问题
- Fixed follow-the-cover blanking out the colour theme row
  修复打开「跟随封面」后「配色主题」那一行变空的问题
- Fixed the Apple Music automation card not showing on the default player
  setting
  修复播放器保持默认设置时，「Apple Music 自动化」卡片不出现的问题
- Fixed a motion cover that could not be checked being reported as a
  mismatch
  修复动态封面「没查成」被当成「对不上」的问题
- Fixed player chips not starting from the left on every row, a stray rule
  in front of sub-rows, and the decision sheet's inputs not lining up
  修复播放器芯片换行后不左对齐、子行前多一条竖线、「解析决策」输入区不对齐的问题

| Chip / 芯片 | dmg | zip |
|---|---|---|
| **Apple Silicon** (M1 and later, recommended) / **Apple M 系列**（推荐） | [Lyrimuse-v1.8.0-macos.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.8.0/Lyrimuse-v1.8.0-macos.dmg) | [Lyrimuse-v1.8.0-macos.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.8.0/Lyrimuse-v1.8.0-macos.zip) |
| **Intel** / **Intel 芯片**（也能在 Apple Silicon 上跑，但体积更大、没必要） | [Lyrimuse-v1.8.0-macos-intel.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.8.0/Lyrimuse-v1.8.0-macos-intel.dmg) | [Lyrimuse-v1.8.0-macos-intel.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.8.0/Lyrimuse-v1.8.0-macos-intel.zip) |

Not sure which one? Check your chip under **About This Mac**.
不确定该下哪个？打开「关于本机」看芯片是 Apple M… 还是 Intel Core…

70 commits since v1.7.0.

**Full Changelog**: https://github.com/Yudaotor/lyrimuse/compare/v1.7.0...v1.8.0

## v1.7.0

New / 新功能
- Deezer joins as a tenth lyrics source, and it covers a lot of ground
  the other nine were thin on: songs in French, Spanish, German,
  Italian, Portuguese, Japanese and Korean that used to come back with
  a poor match, or nothing at all, now have line-by-line lyrics
  新增第十个歌词源 Deezer，中文之外的语种补得最多：法语、西班牙语、德语、
  意大利语、葡萄牙语、日语、韩语的歌，原来搜不到词、或只能搜到一份对不上的，
  现在都能拿到逐行歌词
- Album art moves in the lyrics window when Apple Music has a motion
  cover for the record; there's a switch to turn it off
  Apple Music 提供动态封面的专辑，歌词窗口里那张大封面会动起来；不想要可以
  关掉
- Apple Music radio works properly: lyrics keep up with each track
  instead of drifting, and while the host is talking you see the
  station's name and logo rather than the last song
  Apple Music 电台能用了：每首歌的歌词都跟得上，不再越走越偏；主播说话的时
  候显示电台名和台标，而不是停在上一首歌
- Radio lyrics have their own timing offset, so a station you listen to
  often can be nudged once and stay right
  电台歌词有独立的时间偏移，常听的台校一次就一直对
- Settings can be searched: the matching row is highlighted and scrolled
  to, and a row tucked inside a collapsed group opens up on its own
  设置页可以搜索了：命中的那一行会高亮并滚到眼前，藏在折叠区里的也会自己
  展开
- Updates are installed from a Software Update page inside Settings,
  with the release notes and the progress in the same window
  更新改在设置窗口里的「软件更新」页完成，更新说明和进度都在同一扇窗里
- The desktop lyrics can be pinned to the top center or the bottom
  center above the Dock, or keep floating wherever you drag them
  悬浮歌词可以钉在顶部居中，或者底部居中（在 Dock 之上），也可以继续想拖
  哪儿拖哪儿
- Font, weight and size for the Dynamic Island's lyric text
  灵动岛的歌词可以选字体、粗细和字号
- During an ad the island goes black and tells you how long is left and
  which ad of how many this is; YouTube Music web ads get a skip button
  广告期间灵动岛整卡变黑，写出还剩多久、这是第几条广告；YouTube Music 网页
  广告还多一颗跳过的按钮
- Duet lines stay near the center, so widening the overlay gives long
  lines more room instead of pushing the two voices apart
  对唱的左右两句始终靠着中间，把悬浮窗拉宽是给长句留余地，不会把两句越推
  越远
- Last.fm can skip individual players, so plays from a player you'd
  rather not log stay out of your history; ListenBrainz is untouched
  Last.fm 可以按播放器排除，不想记录的那个播放器放的歌就不会进你的收听历史；
  ListenBrainz 的打卡不受影响
- When a player reports no album name, one is looked up and included in
  the scrobble, so those plays no longer land without an album
  播放器没报专辑名时会去查一个带进打卡，这些歌不会再以「没有专辑」的样子进
  收听历史
- "Show in Spotify" jumps to the track that's playing, and the shuffle
  button is hidden when Spotify says shuffling isn't allowed
  「在 Spotify 中显示」会跳到正在播的这首歌；Spotify 明确不允许随机时，随机
  键不再显示
- Lyrics Manager explains a pick in plain terms: what the runner-up was
  short on, which sources returned the same words, and what was actually
  searched for
  歌词管理会把「为什么挑了这一份」说清楚：落选的那份差在哪、哪几个源给的是
  同一份词、这一轮到底拿哪些词去搜的
- Lyrics Manager marks how many sources answered when a lyric was
  picked, and you can filter for the thin ones
  歌词管理会标出每份歌词当初是在几个源应答的情况下定下的，还能把证据薄的单
  独筛出来
- Buttons on the desktop lyrics and the island respond to hover and
  press, and the island's quick actions show what they do
  悬浮歌词和灵动岛上的按钮，鼠标移上去和按下都有反馈；灵动岛的快捷操作还会
  告诉你那颗键是干什么的
- A newly recognized player is announced on the Dynamic Island as well
  认出一个新播放器时，灵动岛也会提示一次

Improved / 改进
- The Settings sidebar was rebuilt to sit closer to System Settings
  设置侧栏重做，更接近系统「设置」的样子
- Every Settings page opens with its own title and a line saying what it
  is for, and the window is taller so the desktop-lyrics section fits
  without scrolling
  设置里每一页顶上都有页名和一句说明，窗口也加高了，「桌面悬浮歌词」那一整
  段不用滚就看得全
- The "Web" row in the lyrics window's info panel links to the current
  player's own page for the track instead of listing every platform
  歌词窗口「显示简介」里的「网页」只给当前播放器自己那个平台的歌曲页，不再
  把每个平台都列一遍
- The lyrics editor shows the words only; the tag lines no longer push
  them to a second screen
  歌词编辑框只显示歌词正文，不再被十几行标签挤到第二屏
- Tracks without lyrics are sorted more carefully: ones where no source
  answered at all are now told apart from ones that really have no
  lyrics, so a bad moment on the network stops looking like a verdict
  没有歌词的条目分得更细：那一次一个源都没应答的（多半是网络不好），跟确实
  没有歌词的分开了，不会再一律被判成「这首歌没有词」
- The onboarding ends with a little confetti
  引导页最后一页会撒花

Fixed / 修复
- A Japanese original is no longer displaced by an "(English ver.)"
  release
  日文原曲不会再被「(English ver.)」版本顶掉
- A Japanese song with a romanized title no longer comes back with a
  single candidate
  标题是罗马字的日文歌不再只搜出一个候选
- A space between a Japanese artist's family and given name no longer
  leaves every source empty-handed
  日文歌手「姓 名」之间的空格不会再让十个源全部落空
- A track no longer gets lyrics credited to a completely unrelated
  artist
  不会再有歌拿到完全不相干歌手的歌词
- "(Live)" and its Chinese equivalent count as the same version, so the
  right recording from that concert is no longer marked down
  「(Live)」和中文写法的「(现场)」算同一个版本，同一场演唱会的正确录音不会
  再被扣分
- Tracks uploaded by re-post channels, with the artist written into the
  title, can be found now
  搬运频道上传的条目（歌手写在标题里）现在能搜到歌词了
- The source that answered last had its words thrown away, so a song
  could end up with a worse match, or none at all, even though a source
  had found it
  十个源一起查的时候，最后回来的那个源找到的词一直被丢掉——有些歌明明有源
  查到了，最后却用了更差的一份，或者干脆没有
- A track that came up empty once no longer sits on "Searching for
  lyrics…" forever
  一时搜不到词的歌不会再永远停在「搜索歌词中…」
- A brief network problem is no longer recorded as "this track has no
  lyrics"
  网络抖一下不会再被记成「这首歌没有歌词」
- A failed lookup of an artist's other spellings is no longer taken for
  "this artist has none", which used to keep every later song by that
  artist from being searched under the name the sources actually use
  查歌手的其它写法失败时，不会再被当成「这位歌手没有别名」——以前一次失败就
  能让这位歌手后面的歌好几天都不换名字去搜
- Stray character codes that some sources leave in the lyric text
  (`they&apos;re`) are cleaned up, existing lyrics included
  个别源带进来的乱码（`they&apos;re` 这种）会被还原，已存的歌词一并修正
- A real song on YouTube Music is no longer labelled "Ad" for its whole
  duration
  YouTube Music 上的真歌不会再整首显示「广告中」
- After an ad on YouTube Music, the next song no longer starts with a
  few blank seconds where nothing is shown
  YouTube Music 放完广告之后，下一首歌开头不会再有几秒钟什么都不显示
- Spotify's progress no longer runs slow until you pause and resume
  Spotify 的进度不会再偏慢、非要暂停再播一下才准
- "Follow algorithm upgrades" no longer quietly stops working after a
  few upgrades — which also means a throttled background pass may move
  some tracks to a better match over the hours after you update
  「自动跟进算法升级」不会再在升级几次之后悄悄失效——也就是说，更新后的几个
  小时里后台会慢慢重查一部分歌，可能有歌换上更匹配的版本
- A track you're hearing for the first time no longer shows a listen
  count of 2
  第一次听的歌，歌词窗口不会再写着「收听次数 2」
- A Last.fm backfill that succeeded is no longer reported as failed, the
  recent plays refresh right after it, and it always says what it did
  Last.fm 补提交明明成功却报「失败」修了；补完最近记录会立刻刷新，而且一定
  会有一句结果告诉你
- The row of playback buttons under the desktop lyrics appears only when
  the pointer is over the words, not anywhere inside the window
  悬浮歌词下面那排播放按钮，只有鼠标移到歌词上才会出现，不再是指针一进窗口
  （包括两侧的留白）就弹出来
- The dark specks on the island's small cover art are gone
  灵动岛小封面上的黑斑没有了
- Word-level romanization stays under the right characters on every
  line, not only the one being sung
  逐词罗马音在每一行都对齐到对应的字底下，不再只有正在唱的那一行是对的
- Testing one lyrics source no longer keeps spinning after its result is
  already on screen
  单独测一个歌词源，那一格已经出结果了，右上角不会再继续转圈
- Clicking the Dock icon reliably brings the window back
  点 Dock 图标一定会把窗口唤回来

| Chip / 芯片 | dmg | zip |
|---|---|---|
| **Apple Silicon** (M1 and later, recommended) / **Apple M 系列**（推荐） | [Lyrimuse-v1.7.0-macos.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos.dmg) | [Lyrimuse-v1.7.0-macos.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos.zip) |
| **Intel** / **Intel 芯片**（也能在 Apple Silicon 上跑，但体积更大、没必要） | [Lyrimuse-v1.7.0-macos-intel.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos-intel.dmg) | [Lyrimuse-v1.7.0-macos-intel.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos-intel.zip) |

Not sure which one? Check your chip under **About This Mac**.
不确定该下哪个？打开「关于本机」看芯片是 Apple M… 还是 Intel Core…

41 commits since v1.6.0.

**Full Changelog**: https://github.com/Yudaotor/lyrimuse/compare/v1.6.0...v1.7.0

## v1.6.0

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

| Chip / 芯片 | dmg | zip |
|---|---|---|
| **Apple Silicon** (M1 and later, recommended) / **Apple M 系列**（推荐） | [Lyrimuse-v1.6.0-macos.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos.dmg) | [Lyrimuse-v1.6.0-macos.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos.zip) |
| **Intel** / **Intel 芯片**（也能在 Apple Silicon 上跑，但体积更大、没必要） | [Lyrimuse-v1.6.0-macos-intel.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos-intel.dmg) | [Lyrimuse-v1.6.0-macos-intel.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/Lyrimuse-v1.6.0-macos-intel.zip) |

Not sure which one? Check your chip under **About This Mac**.
不确定该下哪个？打开「关于本机」看芯片是 Apple M… 还是 Intel Core…

47 commits since v1.5.0.

**Full Changelog**: https://github.com/Yudaotor/lyrimuse/compare/v1.5.0...v1.6.0

## v1.5.0

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

| Chip / 芯片 | dmg | zip |
|---|---|---|
| **Apple Silicon** (M1 and later, recommended) / **Apple M 系列**（推荐） | [Lyrimuse-v1.5.0-macos.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos.dmg) | [Lyrimuse-v1.5.0-macos.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos.zip) |
| **Intel** / **Intel 芯片**（也能在 Apple Silicon 上跑，但体积更大、没必要） | [Lyrimuse-v1.5.0-macos-intel.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos-intel.dmg) | [Lyrimuse-v1.5.0-macos-intel.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.5.0/Lyrimuse-v1.5.0-macos-intel.zip) |

Not sure which one? Check your chip under **About This Mac**.
不确定该下哪个？打开「关于本机」看芯片是 Apple M… 还是 Intel Core…

26 commits since v1.4.0.

**Full Changelog**: https://github.com/Yudaotor/lyrimuse/compare/v1.4.0...v1.5.0

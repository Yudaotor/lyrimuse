v1.7.0

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
- Clicking the Dock icon reliably brings the window back
  点 Dock 图标一定会把窗口唤回来

## Download / 下载

| Chip / 芯片 | dmg | zip |
|---|---|---|
| **Apple Silicon** (M1 and later, recommended) / **Apple M 系列**（推荐） | [Lyrimuse-v1.7.0-macos.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos.dmg) | [Lyrimuse-v1.7.0-macos.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos.zip) |
| **Intel** / **Intel 芯片**（也能在 Apple Silicon 上跑，但体积更大、没必要） | [Lyrimuse-v1.7.0-macos-intel.dmg](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos-intel.dmg) | [Lyrimuse-v1.7.0-macos-intel.zip](https://github.com/Yudaotor/lyrimuse/releases/download/v1.7.0/Lyrimuse-v1.7.0-macos-intel.zip) |

Not sure which one? Check your chip under **About This Mac**.
不确定该下哪个？打开「关于本机」看芯片是 Apple M… 还是 Intel Core…

34 commits since v1.6.0.

**Full Changelog**: https://github.com/Yudaotor/lyrimuse/compare/v1.6.0...v1.7.0

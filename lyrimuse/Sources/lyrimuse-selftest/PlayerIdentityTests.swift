import LyrimuseCore
import Foundation

// 播放器身份 / 信任列表 / 播放模式 / 多选 / 健康徽标。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runPlayerIdentityTests() {
    // ---- bundleID → 数据源档位映射 ----
    do {
        typealias L = LocalPlaybackSource
        expectEqual(L.positionSourceTier(forBundleID: "com.apple.Music") == .precise, true,
                    "档位映射: Apple Music → precise")
        expectEqual(L.positionSourceTier(forBundleID: "com.spotify.client") == .cleanExtrapolated, true,
                    "档位映射: Spotify → cleanExtrapolated")
        expectEqual(L.positionSourceTier(forBundleID: "com.tencent.QQMusicMac") == .noisyFloored, true,
                    "档位映射: QQ 音乐 → noisyFloored")
        expectEqual(L.positionSourceTier(forBundleID: "com.netease.163music") == .noisyFloored, true,
                    "档位映射: 网易云 → noisyFloored")
        // 酷狗归 cleanExtrapolated 是实测定的:它播放期间不刷新锚点,位置全靠墙钟外推,
        // 23 秒累计偏差 +0.0011s、小数位完全连续(不是 QQ 那种整秒下取整)。归错档会给它
        // 挂上前向棘轮,而棘轮的前提对纯外推源不成立。
        expectEqual(L.positionSourceTier(forBundleID: "com.kugou.mac.Music") == .cleanExtrapolated, true,
                    "档位映射: 酷狗 → cleanExtrapolated(2026-08-21 实测:纯外推、无量化)")
        expectEqual(L.shouldRatchetForward(reported: 10, predicted: 5, tier: .cleanExtrapolated), false,
                    "档位映射: 酷狗这一档不吃前向棘轮")
        // 2026-08-21 翻了默认档:noisyFloored 的两样东西(1.0s 大门槛 + 前向棘轮)只对**整秒
        // 量化**的源成立(棘轮前提是"报告值 ≤ 真实位置"),而实测所有走 media-control 的源都是
        // 纯外推、无量化(酷狗 23 秒累计偏差 +0.0011s;Arc 小数位完全连续)。所以量化源是少数派,
        // 显式登记它们、其余走 cleanExtrapolated。nil 也走这一档:"保守"应该是"别用前提不成立
        // 的棘轮",不是"选门槛最大的那一档"。
        expectEqual(L.positionSourceTier(forBundleID: nil) == .cleanExtrapolated, true,
                    "档位映射: 没有来源信息时归 cleanExtrapolated(不套前提不成立的棘轮)")
        expectEqual(L.positionSourceTier(forBundleID: "company.thebrowser.Browser") == .cleanExtrapolated,
                    true, "档位映射: 信任的未知 App(实测纯外推)归 cleanExtrapolated")
        expectEqual(L.shouldRatchetForward(reported: 10, predicted: 5,
                                           tier: L.positionSourceTier(forBundleID: "company.thebrowser.Browser")),
                    false, "档位映射: 未知源不吃前向棘轮")
    }

    // ---- MusicPlaybackMode: 播放模式档位轮换,按播放器有没有「单曲循环」分两套(2026-08-14) ----
    //
    // Spotify 的 AppleScript 字典里 `repeating` 只是布尔,够不到 repeat-one —— 所以它的按钮
    // 只在 列表 ↔ 随机 两档之间倒。轮换必须**闭合**:不管从哪一档起步,反复点下去都要能回到
    // 原点,否则按钮会卡在一个出不来的档位上。
    do {
        typealias Mode = MusicPlaybackController.MusicPlaybackMode

        // Apple Music:三档循环
        expectEqual(Mode.list.next(allowsRepeatOne: true), .shuffle, "播放模式: 列表→随机")
        expectEqual(Mode.shuffle.next(allowsRepeatOne: true), .repeatOne, "播放模式: 随机→单曲")
        expectEqual(Mode.repeatOne.next(allowsRepeatOne: true), .list, "播放模式: 单曲→列表")

        // 列表循环档(2026-08-21 补,AM 循环键三态):全部→单曲;够不到单曲的播放器直接回列表
        expectEqual(Mode.repeatAll.next(allowsRepeatOne: true), .repeatOne, "播放模式: 全部→单曲")
        expectEqual(Mode.repeatAll.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 全部→列表")

        // Spotify:跳过单曲那一档
        expectEqual(Mode.list.next(allowsRepeatOne: false), .shuffle, "播放模式(无单曲): 列表→随机")
        expectEqual(Mode.shuffle.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 随机→列表")
        // 起步档位恰好是单曲时(用户在 Apple Music 里开了单曲循环,再切到 Spotify 播放)也要能出来
        expectEqual(Mode.repeatOne.next(allowsRepeatOne: false), .list, "播放模式(无单曲): 单曲→列表")

        // 轮换闭合:连点下去不能卡在某一档出不来。
        //
        // ⚠️ 例外是**只能离开、回不去**的过渡态,它们能一步走掉(上面那些断言)就够了:
        // ① "单曲档 + 不支持单曲"(用户在 Apple Music 里开着单曲循环、切到 Spotify 播放时
        //   可能读到它),回不去正是设计意图,不是卡住;第一版把它也算进"必须回到原点",
        //   断言直接红了,是断言写宽了,不是实现错了。
        // ② 列表循环档(2026-08-21 新增):next() 的老三档轮换不产出它 —— 产出它的是歌词
        //   窗口循环键自己的三态 switch(关→全部→单曲→关),cyclePlaybackMode 读到它时
        //   顺 AM 语义走 全部→单曲,不需要转回来。
        for allows in [true, false] {
            for start in Mode.allCases {
                var cur = start
                var seen: [Mode] = []
                for _ in 0..<4 { cur = cur.next(allowsRepeatOne: allows); seen.append(cur) }
                let startIsUnreachable = (!allows && start == .repeatOne) || start == .repeatAll
                if !startIsUnreachable {
                    expectEqual(seen.contains(start), true,
                                "播放模式: allowsRepeatOne=\(allows) 从 \(start.rawValue) 起步能转回原点")
                }
                if !allows {
                    expectEqual(seen.contains(.repeatOne), false,
                                "播放模式: allowsRepeatOne=false 时永远不会落到单曲档")
                }
            }
        }

        // 能力表:只有 Apple Music 有单曲循环;QQ音乐/网易云连扩展控制都没有(两个 .app 无 .sdef)
        expectEqual(MusicPlaybackController.supportsRepeatOne(.appleMusic), true, "能力: Apple Music 有单曲循环")
        expectEqual(MusicPlaybackController.supportsRepeatOne(.spotify), false, "能力: Spotify 没有单曲循环")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.appleMusic), true, "能力: Apple Music 支持音量/模式")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.spotify), true, "能力: Spotify 支持音量/模式")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.qqMusic), false, "能力: QQ音乐不支持")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.netease), false, "能力: 网易云不支持")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.kugou), false, "能力: 酷狗不支持(无 .sdef)")
        expectEqual(MusicPlaybackController.supportsRepeatOne(.kugou), false, "能力: 酷狗没有单曲循环")
    }

    // ---- 信任列表:「自动识别」放开到任意 App(2026-08-21) ----
    //
    // 白名单不只挡显示,**也挡打卡**(collector 的 poller.isTracked),所以口径是"用户显式
    // 同意"而不是"一律接受"—— 一律接受等于让 YouTube/播客写进永久收听历史。这里守的是
    // 那道闸的语义:内置的永远认、信任过的认、其它一律不认。
    do {
        typealias T = TrustedPlayers
        let trusted = ["com.foobar.mac": "Foobar2000", "com.some.player": ""]

        // 内置五个:跟信任列表无关,永远认(空名单也认)
        for player in PlaybackPlayer.allCases where player != .auto {
            expectEqual(T.isAccepted(player.bundleIdentifier, trusted: [:]), true,
                        "信任列表: 内置播放器 \(player) 不依赖名单")
        }
        // 信任过的:认。名字是空串(反查不到 App 名)也照样认 —— 名字只影响显示/标签,不影响准入
        expectEqual(T.isAccepted("com.foobar.mac", trusted: trusted), true, "信任列表: 信任过的 App 被接受")
        expectEqual(T.isAccepted("com.some.player", trusted: trusted), true,
                    "信任列表: 名字为空(反查不到)不影响准入")
        // 没信任过的:一律不认 —— 这条就是"默认一条垃圾都进不来"
        expectEqual(T.isAccepted("com.apple.Safari", trusted: trusted), false, "信任列表: 陌生 App 默认不接受")
        expectEqual(T.isAccepted("", trusted: trusted), false, "信任列表: 空 bundle id 不接受")
        expectEqual(T.isAccepted(nil, trusted: trusted), false, "信任列表: nil 不接受")
        // .auto 自己那个空 bundle id 不能被当成"匹配上了"
        expectEqual(T.isAccepted(PlaybackPlayer.auto.bundleIdentifier, trusted: [:]), false,
                    "信任列表: 自动识别的空 bundle id 不算命中")
    }

    // ---- Safari 那道 JS 开关:读不到 ≠ 关着(2026-09-02) ----
    //
    // 真实bug(用户原话「可以现在就是勾着的啊」):Safari 里那个「允许 Apple 事件中的
    // JavaScript」确实勾着、自检也实测通过(界面绿字「现在可以被驱动了」),界面却同时橙字
    // 告警「这个开关已经被关掉了——重启后就会失效」,还把菜单路径指引整块摆出来让用户再去
    // 勾一遍(而它本来就勾着,照做无事发生)。
    //
    // 根因:`CFPreferencesCopyAppValue` 返回 nil 被判成 `.disabled`。nil 有两种成因——真的
    // 没设过、以及**读不到**(`com.apple.Safari` 是 TCC 保护域,别的 App 读它要「完全磁盘访问
    // 权限」,没有才是常态),这里分不出来,所以只能是 `.unknown`。隔壁 Chromium 分支一直就是
    // 这么做的,Safari 这边是漏了。实测坐实:同一台机器同一个值,终端身份(有权限)读到 1、
    // App 身份读到 nil —— 读得到读不到只取决于调用方的 TCC 身份,跟开关死活无关。
    //
    // 连带影响:`browserJSLikelyWorking` 对 `.disabled` 是一票否决,所以误判还会让整张卡
    // 永远收敛不到"已配好"、角标一直挂着。
    do {
        typealias P = BrowserAutomationPermission
        expectEqual(P.safariStatus(fromPrefValue: nil), P.Status.unknown,
                    "Safari 开关: 读不到(nil)必须是 unknown —— 判成 disabled 就会对着勾着的开关报「已经被关掉了」")
        expectEqual(P.safariStatus(fromPrefValue: true as CFPropertyList), P.Status.enabled,
                    "Safari 开关: 读到 true → enabled")
        expectEqual(P.safariStatus(fromPrefValue: false as CFPropertyList), P.Status.disabled,
                    "Safari 开关: 读到 false → disabled(这一档才是「确定关着」)")
        // defaults 写进去的常是 NSNumber 1/0 而不是 Bool,两种形态都要认。
        expectEqual(P.safariStatus(fromPrefValue: NSNumber(value: 1) as CFPropertyList), P.Status.enabled,
                    "Safari 开关: NSNumber 1 → enabled")
        expectEqual(P.safariStatus(fromPrefValue: NSNumber(value: 0) as CFPropertyList), P.Status.disabled,
                    "Safari 开关: NSNumber 0 → disabled")
    }

    // ---- 「这不是一首歌」守卫:信任的 App 报空歌手/空专辑就丢掉(2026-08-21) ----
    //
    // 判据跟 collector 的 isAdBreak 完全一致(`album == "" || artist == ""`),区别只在作用域:
    // 那个只服务 Spotify 广告,这个服务信任列表。样本全是真抓的,四份:
    //   酷狗 周杰伦/七里香、Spotify 方大同/Soulboy、Apple Music 卢广仲/100种生活 → 是歌
    //   Arc 放视频 两次:①artist/album 都空 ②artist=频道名「Dream in reality」、album 仍空
    // **album 是这四份里唯一 100% 分对的字段** —— ② 正是"只卡 artist 不够"的证据。
    do {
        typealias T = TrustedPlayers
        let arc = "company.thebrowser.Browser"
        let trusted = [arc: "Arc"]

        // Arc 两份真实样本都该被丢掉
        expectEqual(T.notASong(bundleID: arc, artist: "", album: "", trusted: trusted), true,
                    "非歌守卫: artist/album 都空 → 丢掉(Arc 第一份样本)")
        expectEqual(T.notASong(bundleID: arc, artist: "Dream in reality", album: "", trusted: trusted), true,
                    "非歌守卫: YouTube 频道名进了 artist 但 album 空 → 仍然丢掉(这是只卡 artist 不够的证据)")
        expectEqual(T.notASong(bundleID: arc, artist: "", album: "某专辑", trusted: trusted), true,
                    "非歌守卫: 反方向(artist 空)同样丢掉")
        expectEqual(T.notASong(bundleID: arc, artist: nil, album: nil, trusted: trusted), true,
                    "非歌守卫: 字段缺失等于空")
        expectEqual(T.notASong(bundleID: arc, artist: "  ", album: "某专辑", trusted: trusted), true,
                    "非歌守卫: 纯空白按空处理")

        // 三个真音乐 App 的真实样本都该放行
        for sample in [("周杰伦", "七里香"), ("方大同", "Soulboy"), ("卢广仲", "100种生活")] {
            expectEqual(T.notASong(bundleID: arc, artist: sample.0, album: sample.1, trusted: trusted), false,
                        "非歌守卫: 两个字段都齐就放行(\(sample.0) / \(sample.1))")
        }

        // 内置播放器不受这条约束 —— 它们各有既有守卫,卷进来等于偷偷改既有行为
        for player in PlaybackPlayer.allCases where player != .auto {
            expectEqual(T.notASong(bundleID: player.bundleIdentifier, artist: "", album: "", trusted: trusted),
                        false, "非歌守卫: 内置播放器 \(player) 不受影响")
        }
        // 没信任过的:由准入层挡,这里返回 false —— 别掩盖真实原因
        expectEqual(T.notASong(bundleID: "com.apple.Safari", artist: "", album: "", trusted: trusted), false,
                    "非歌守卫: 没信任过的由准入层挡,不在这条守卫里报 true")

        // ---- Safari 媒体代理进程(2026-09-02,王力宏《你不知道的事》Safari 网页播放案) ----
        // Safari 播网页音频报的是 com.apple.WebKit.GPU,信任表存的是宿主 com.apple.Safari。
        // 原来这里裸查 trusted[bundleID],对代理进程恒落空 → Safari 播非歌视频这道守卫恒不
        // 生效。collector 侧 trustedPlaybackNotASong 同一个洞、同日一起修(那边还多两处:
        // getAutoDetectedState 整条丢播放、mediaPlayerLabel 谎报 Apple Music)。
        let safariTrusted = ["com.apple.Safari": "Safari"]
        let webkitGPU = "com.apple.WebKit.GPU"
        expectEqual(T.notASong(bundleID: webkitGPU, artist: "某频道", album: "", trusted: safariTrusted), true,
                    "非歌守卫: Safari 代理进程播 album 为空的内容 → 经别名解析后守卫生效")
        expectEqual(T.notASong(bundleID: webkitGPU, artist: "王力宏", album: "十八般武藝", trusted: safariTrusted), false,
                    "非歌守卫: Safari 代理进程播字段齐全的真歌 → 放行")
        expectEqual(T.notASong(bundleID: webkitGPU, artist: "", album: "", trusted: trusted), false,
                    "非歌守卫: 宿主 Safari 不在信任表时代理进程照旧不归这条守卫管")
    }

    // ---- 播放器身份契约:rawValue / bundle id 必须跟 collector 逐字对应 ----
    //
    // rawValue 是两侧通过共享 features.json 的 "player" 字段交换的字符串(Go 侧 features.go 的
    // playerXxx 常量);bundle id 是核对"系统级 Now Playing 是谁在报"的唯一依据(Go 侧 system.go
    // 的 xxxBundleID 常量)。这两组字符串任一侧改了名而另一侧没跟上,表现都是**静默失效**:
    // 用户在设置里选了某个播放器,collector 认不出这个值就默默兜底成"自动识别",界面一切正常、
    // 只是选择没生效 —— 所以这里把它们钉成断言,而不是靠"记得两边一起改"。
    do {
        let expected: [PlaybackPlayer: (raw: String, bundle: String)] = [
            .appleMusic: ("apple_music", "com.apple.Music"),
            .qqMusic: ("qq_music", "com.tencent.QQMusicMac"),
            .netease: ("netease_music", "com.netease.163music"),
            .kugou: ("kugou_music", "com.kugou.mac.Music"),
            .spotify: ("spotify", "com.spotify.client"),
        ]
        for (player, want) in expected {
            expectEqual(player.rawValue, want.raw, "播放器契约: \(player) 的 rawValue")
            expectEqual(player.bundleIdentifier, want.bundle, "播放器契约: \(player) 的 bundle id")
            expectEqual(PlaybackPlayer(rawValue: want.raw) == player, true,
                        "播放器契约: \(want.raw) 能解回 \(player)")
        }
        // .auto 刻意没有固定 bundle id(见 PlaybackPlayer 注释),空串让"唤起播放器"那类联动
        // 自然 no-op。
        expectEqual(PlaybackPlayer.auto.bundleIdentifier, "", "播放器契约: 自动识别没有固定 bundle id")
        // 全部 case 都得在上表里 —— 新加一个播放器就必须来这里补一行,漏了这条断言会红。
        expectEqual(PlaybackPlayer.allCases.count, expected.count + 1,
                    "播放器契约: 新增播放器要同步补进契约表(+1 是 .auto)")
        // bundle id 不能撞车:复制粘贴加播放器时最容易犯,而撞车的表现是"选了 A 却跟着 B 走"。
        let bundles = PlaybackPlayer.allCases.filter { $0 != .auto }.map(\.bundleIdentifier)
        expectEqual(Set(bundles).count, bundles.count, "播放器契约: bundle id 互不重复")
    }

    // ---- 播放器多选(2026-09-01):Set<PlaybackPlayer>.soleExplicitPlayer ----
    //
    // 这是"排除自动识别之后,选中集合里能不能唯一确定一个具体播放器"的判据——
    // PlaybackPlayerPreference.soleExplicitPlayer(读共享文件)、SettingsView 的
    // companionCard("打开 Lyrimuse 时启动 X")、LyricsWindowView 的 idlePlayer、
    // AppDelegate 的"打开 Lyrimuse 时唤起播放器"都靠它决定"有没有一个唯一答案可以显示/
    // 动作"。只测这份不碰磁盘的纯逻辑,不测 PlaybackPlayerPreference.selected 本身
    // (那个读的是真实共享文件,写测试数据进去会干扰这台机器上真的在跑的 collector/App)。
    do {
        expectEqual(Set<PlaybackPlayer>([.auto]).soleExplicitPlayer, nil,
                    "多选.soleExplicitPlayer: 纯自动识别没有唯一具体播放器")
        expectEqual(Set<PlaybackPlayer>([.appleMusic]).soleExplicitPlayer, .appleMusic,
                    "多选.soleExplicitPlayer: 单选一个具体播放器,原样返回")
        expectEqual(Set<PlaybackPlayer>([.appleMusic, .auto]).soleExplicitPlayer, .appleMusic,
                    "多选.soleExplicitPlayer: 具体播放器+自动识别一起选,排除 auto 后仍唯一")
        expectEqual(Set<PlaybackPlayer>([.appleMusic, .qqMusic]).soleExplicitPlayer, nil,
                    "多选.soleExplicitPlayer: 选了两个具体播放器,没有唯一答案")
        expectEqual(Set<PlaybackPlayer>([.appleMusic, .qqMusic, .auto]).soleExplicitPlayer, nil,
                    "多选.soleExplicitPlayer: 两个具体播放器+auto,排除 auto 后仍不唯一")
        expectEqual(Set<PlaybackPlayer>([]).soleExplicitPlayer, nil,
                    "多选.soleExplicitPlayer: 空集不该崩、也没有唯一答案(理论不该发生,但函数要安全)")
    }

    // ---- YouTube Music 广告判据(2026-09-02)----
    //
    // 浏览器里播 YouTube Music 此前常常不被识别:它的 album 常常是空的,撞上 TrustedPlayers.notASong
    // 那道防视频守卫。不能简单免检 album —— 实测广告的 artist 是广告主频道名、**非空**,免检
    // 之后广告会被当成歌收下(仓库里已记过 Spotify 那次"Now Streaming on Hulu." 进收听历史)。
    // 所以改成问页面本身。判据与真实样本见 YouTubeMusicAdProbe 的头注。
    do {
        typealias P = YouTubeMusicAdProbe

        // ⓪ 三条出口(`gate`)。2026-09-03 从 MediaControlClient 那个 private static 里收出来的
        //    纯函数 —— 收出来的动机就是"其中一条被特意改过、却没有任何覆盖"。
        //    改的那条:判定为广告时**不再丢弃快照**,而是放行、交给
        //    LocalPlaybackSource.isCurrentTrackAdBreak 标成广告驱动 UI(用户要求 chrome 上
        //    YT Music 的广告也像 Spotify 那样显示「广告中」)。丢弃的话 UI 拿不到任何东西,
        //    30 秒广告期间灵动岛/悬浮窗会整个塌成"没有在播放"再弹回来。
        //    ⚠️ 放行**不等于**会被记录:Swift 侧一行 scrobble 都不发,提交 listen 全在
        //    collector(lastfm.go / lb.go),那边由 ytmusicad.go 自己拦。
        expectEqual(P.gate(artist: "Michael Jackson", verdict: .song), .acceptAsSong,
                    "广告闸: 判定是歌 → 放行当歌")
        expectEqual(P.gate(artist: "KAO Hong Kong", verdict: .ad), .acceptAsAd,
                    "广告闸: 判定是广告 → **放行并标成广告**(不是丢掉),UI 才能显示「广告中」")
        expectEqual(P.gate(artist: "KAO Hong Kong", verdict: nil), .reject,
                    "广告闸: 还没探到 → fail-closed 丢掉(下一轮就好)")
        // artist 为空一律拒,**不看判定** —— 真曲目必有歌手,顺带省掉一次 AppleEvent。
        // 这三条钉住"短路发生在读判定之前":哪怕判定说是歌也不放行。
        expectEqual(P.gate(artist: "", verdict: .song), .reject, "广告闸: artist 为空 → 拒,即便判定说是歌")
        expectEqual(P.gate(artist: "   ", verdict: .ad), .reject, "广告闸: artist 全空白 → 拒")
        expectEqual(P.gate(artist: nil, verdict: nil), .reject, "广告闸: artist 为 nil → 拒")
        // 展示口径与 gate **方向相反**:拿不准时 gate 宁枉勿纵(丢掉),贴标签必须宁纵勿枉。
        // 探针会真的超时(osascript 卡住 / 浏览器没给自动化权限),那一档若跟着 gate 走,
        // 就会在一首**真歌**上打「广告中」。
        expectEqual(P.showsAdBadge(verdict: .ad), true, "广告标签: 判定是广告 → 点亮「广告中」")
        expectEqual(P.showsAdBadge(verdict: .song), false, "广告标签: 判定是歌 → 不点亮")
        expectEqual(P.showsAdBadge(verdict: nil), false,
                    "广告标签: 判定**缺失**时不点亮 —— 探针超时不能让真歌被贴上「广告中」(与 gate 的 fail-closed 方向相反)")

        // ① 判定表。2026-09-02 成对采样的真实读数:广告期间三个标志同时命中(22/22 连续样本、
        //    横跨两条不同广告),真歌期间三条全灭。
        expectEqual(P.parse("1|1|1")?.verdict, .ad, "广告判据: 真实广告样本(三条全中)判成广告")
        expectEqual(P.parse("0|0|0")?.verdict, .song, "广告判据: 真实歌曲样本(三条全灭)判成歌")
        // 任一命中就算广告 —— 误判成广告只丢这一轮(下一轮自我纠正),误判成歌是永久写进
        // Last.fm。这三条同时也是"YouTube 改了某个 class 名"时的兜底路径。
        expectEqual(P.parse("1|0|0")?.verdict, .ad, "广告判据: 只有 ad-showing 命中也算广告")
        expectEqual(P.parse("0|1|0")?.verdict, .ad, "广告判据: 只有广告徽章命中也算广告")
        expectEqual(P.parse("0|0|1")?.verdict, .ad, "广告判据: 只有裸标题命中也算广告")
        // 形状不认识一律 nil ——**不猜**,让调用方 fail-closed。
        // ⚠️ `"1|0|0|0"` 2026-09-03 从这张表里**移走**了:第四段现在是专辑名(任意文本),
        // 它是一个合法的读数(广告 + 专辑名"0"),不再是"形状不对"。见下面第四段那一组。
        for raw in ["NOTFOUND", "", "   \n", "1|0", "1|x|0", "true|false|false"] {
            expectEqual(P.parse(raw), nil, "广告判据: 形状不认识时不做推断(\(raw.debugDescription))")
        }
        // AppleScript 有时把返回值再包一层双引号。
        expectEqual(P.parse("\"1|1|1\"")?.verdict, .ad, "广告判据: 脱掉 AppleScript 多包的引号")
        expectEqual(P.parse("\"0|0|0\"\n")?.verdict, .song, "广告判据: 脱引号+换行")

        // ①-b 第四段:页面上读到的专辑名(2026-09-03)。
        //
        // 起因是用户报「YouTube Music 播一张专辑时,第一首歌不上送专辑名」。实测坐实那是
        // YT Music 自己的疏漏(队列第一首的 MediaSession 里 album 恒空,页面 byline 上却有),
        // 详见 YouTubeMusicAdProbe.albumPatch 的注释和那张四行实测表。
        expectEqual(P.parse("0|0|0|Already Gone")?.album, "Already Gone",
                    "专辑补齐: 第四段就是页面上读到的专辑名")
        expectEqual(P.parse("0|0|0|Already Gone")?.verdict, .song,
                    "专辑补齐: 带专辑名不影响前三段的判定")
        expectEqual(P.parse("0|0|0|")?.album, "", "专辑补齐: 页面上没读到 → 空串,不是解析失败")
        expectEqual(P.parse("0|0|0")?.album, "", "专辑补齐: 只有三段(旧形状)也照样解得出,专辑为空")
        // ⚠️ 专辑名是**任意文本**,可以自带分隔符。`maxSplits: 3` 保证第四段原样保留 ——
        // 用普通 split 的话这条会退化成"形状不对"而整条读数被丢掉(连带丢掉广告判定)。
        expectEqual(P.parse("0|0|0|A|B")?.album, "A|B", "专辑补齐: 专辑名里自带 | 时原样保留")
        expectEqual(P.parse("1|0|0|0")?.album, "0",
                    "专辑补齐: 第四段是文本不是标志位,\"0\" 是一个合法的专辑名")
        expectEqual(P.parse("0|0|0|  Already Gone  ")?.album, "Already Gone",
                    "专辑补齐: 两端空白削掉")
        expectEqual(P.parse("0|0|0|Already\nGone")?.album, "Already Gone",
                    "专辑补齐: 中间的换行压成空格(osascript 输出按行读,混进换行会很难查)")

        // ①-c 补不补、补成什么(纯函数,三条同时成立才补)。
        let song = P.Reading(verdict: .song, album: "Already Gone")
        expectEqual(P.albumPatch(reported: "", reading: song), "Already Gone",
                    "专辑补齐: 上游报空 + 判定是歌 + 探针有值 → 补上")
        expectEqual(P.albumPatch(reported: nil, reading: song), "Already Gone",
                    "专辑补齐: 上游是 nil 同样算空")
        expectEqual(P.albumPatch(reported: "   ", reading: song), "Already Gone",
                    "专辑补齐: 上游全是空白同样算空")
        // ⚠️ 上游报了就一律不动 —— 探针只补缺,不做纠正。第二首起 MediaSession 自己有专辑名,
        // 那份是权威(而页面 byline 在换歌那一瞬间可能还停在上一首)。
        expectEqual(P.albumPatch(reported: "The Essential Michael Jackson", reading: song), nil,
                    "专辑补齐: 上游已经有专辑名 → 一个字都不动")
        // ⚠️ 广告不补:广告没有专辑,而广告期间页面 byline 读到的多半是上一首歌的残留,
        // 补上去等于给广告安一个别人的专辑名。
        expectEqual(P.albumPatch(reported: "", reading: P.Reading(verdict: .ad, album: "Already Gone")),
                    nil, "专辑补齐: 判定是广告 → 不补(byline 上那个多半是上一首的残留)")
        expectEqual(P.albumPatch(reported: "", reading: nil), nil, "专辑补齐: 还没探到 → 不补")
        expectEqual(P.albumPatch(reported: "", reading: P.Reading(verdict: .song, album: "  ")), nil,
                    "专辑补齐: 探针读到的是空白 → 不补,别把专辑名写成一串空格")

        // ② ⚠️ JS 源码里不许出现双引号。它整段要嵌进 AppleScript 的双引号字符串,而
        //    `execute … javascript` 会把返回值里已有的双引号**真的**转义成反斜杠(不是显示
        //    转义),整段被二次转义之后拿去比 contains 会稳定判 false —— 这是
        //    BrowserPositionProbe.youtubeMusicScript 为此放弃 JSON.stringify 的同一个坑。
        expectEqual(P.probeJS.contains("\""), false,
                    "广告判据: JS 源码不含双引号(嵌进 AppleScript 会被二次转义打坏)")

        // ③ 三个信号一个都不能少 —— 少一个就是悄悄削弱了判据,而且不会有任何报错。
        for marker in ["ad-showing", "ytp-ad-badge", "YouTube Music", "NOTFOUND"] {
            expectEqual(P.probeJS.contains(marker), true, "广告判据: JS 里必须有 \(marker)")
        }

        // ④ 生成的 AppleScript 的硬约束。写错了不会编译报错、只会在运行时静默失败。
        for family in [BrowserAutomationPermission.Family.chromium, .safari] {
            let s = P.buildAppleScript(bundleID: "com.google.Chrome", family: family)
            // 用 bundle id 而不是写死 App 名字(不受"App 被改名/装了变体版本"影响)。
            expectEqual(s.contains("tell application id \"com.google.Chrome\""), true,
                        "广告判据/\(family): 用 tell application id")
            // 只在 music.youtube.com 的标签页上执行 —— 普通 YouTube 视频不受这条链路影响。
            expectEqual(s.contains(P.hostMarker), true, "广告判据/\(family): 按 music.youtube.com 过滤标签页")
            // `with timeout` 是把 Arc 那种"挂起不返回"变成抓得住的错误的唯一手段(裸 try
            // 抓不住挂起),两处执行点都必须有。
            expectEqual(s.components(separatedBy: "with timeout of").count - 1, 2,
                        "广告判据/\(family): 两处执行点都套了 with timeout")
            expectEqual(s.contains("return \"NOTFOUND\""), true, "广告判据/\(family): 有兜底返回")
        }
        // 两种方言不能搞混。
        let chromium = P.buildAppleScript(bundleID: "com.google.Chrome", family: .chromium)
        let safari = P.buildAppleScript(bundleID: "com.apple.Safari", family: .safari)
        expectEqual(chromium.contains("do JavaScript"), false, "广告判据: chromium 不该出现 Safari 方言")
        expectEqual(safari.contains("do JavaScript"), true, "广告判据: safari 用 do JavaScript")
        expectEqual(safari.contains("execute ("), false, "广告判据: safari 不该出现 Chromium 方言")

        // ⑤ ⚠️ 跨语言防漂:同一份判据在 collector(Go)里还有一份,两边必须同时改
        //    (跟 TrustedPlayers.notASong / trustedPlaybackNotASong 那一对是同样的关系)。
        //    这里直接读 Go 源码对账 —— 光靠注释里那句"两边必须同时改"拦不住漏改。
        let goSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // …/Sources
            .deletingLastPathComponent()   // …/lyrimuse
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("lyrimuse-collector/ytmusicad.go")
        if let go = try? String(contentsOf: goSource, encoding: .utf8) {
            // `browse/MPREb` / `ytmusic-player-bar` 是 2026-09-03 加的专辑名读取(两侧同一份 JS,
            // 漏改一边的后果是:Swift 侧 UI 上有专辑名、collector 侧拿不到,于是歌词匹配和
            // 打卡到 Last.fm 的专辑字段仍然是空的 —— 两边行为不一致,查起来极难对上。
            for marker in ["ad-showing", "ytp-ad-badge", "YouTube Music", "NOTFOUND",
                           "browse/MPREb", "ytmusic-player-bar", P.hostMarker] {
                expectEqual(go.contains(marker), true,
                            "广告判据/跨语言: collector 侧 ytmusicad.go 也必须有 \(marker)(两边同时改)")
            }
            // 超时秒数两边对齐 —— 不一致会让两侧在"浏览器不回"时表现不一样,排查时极难对上。
            expectEqual(go.contains("ytmusicAdProbeEventTimeout = \(P.eventTimeoutSeconds)"), true,
                        "广告判据/跨语言: AppleScript 事件超时两边同值")
            // ⚠️ 2026-09-03 加:上面那串 marker 只能保证"关键字都在",保证不了两边的 JS **真的
            // 一样** —— 少一个分号、选择器顺序不同、少读一个字段,marker 全过、行为却已经漂了。
            // 这一条直接把两段 JS 拼出来逐字比。Go 侧是反引号串用 `+` 拼的,取出所有反引号里的
            // 片段接起来就是最终那串。
            //
            // 这条守卫是有代价的:两边的 JS 从此**一个字符都不许差**(连注释性的空格都不行)。
            // 那正是想要的 —— 它们本来就该是同一段代码,只是被两种语言各抄了一份。
            if let start = go.range(of: "const ytmusicAdProbeJS = "),
               let end = go.range(of: "\n\n", range: start.upperBound ..< go.endIndex) {
                let block = String(go[start.upperBound ..< end.lowerBound])
                // 反引号成对:奇数下标的片段就是字符串内容。
                let chunks = block.components(separatedBy: "`")
                let goJS = chunks.enumerated()
                    .filter { $0.offset % 2 == 1 }
                    .map(\.element)
                    .joined()
                expectEqual(goJS, P.probeJS,
                            "广告判据/跨语言: 两侧的探针 JS 必须逐字相同(两边同时改)")
            } else {
                expectEqual(true, false, "广告判据/跨语言: 在 ytmusicad.go 里找不到 ytmusicAdProbeJS")
            }
        } else {
            expectEqual(true, false, "广告判据/跨语言: 读不到 lyrimuse-collector/ytmusicad.go(路径挪了?)")
        }
    }


    // ---- Spotify 网页版广告:问页面(2026-09-03) ----
    //
    // 起因:原生 Spotify 的广告一直能显示「广告中」,而**浏览器里的** Spotify 广告会让整个
    // UI 塌 30 秒(菜单栏收回小图标、灵动岛/悬浮窗消失)。根因是它的字段形状是
    // `title="广告" artist="" album=""` —— **artist 为空**,在
    // `MediaControlClient.trustedPlaybackRejected` 里那道"歌手名为空一律丢"的短路之前就死了,
    // 页面复核根本轮不到(YT Music 广告的 artist 是广告主频道名、非空,所以走得到)。
    //
    // 判据来自 2026-09-03 现场抓的对照样本(Safari + open.spotify.com,同一张专辑连播):
    //   4 次歌曲态(三年二班 / 東風破 / 妳聽得到 / 同一種調調) → 0|0|0|0
    //   6 次广告态(跨 3 条连续广告,Uber「第 1 个,共 3 个」) → 1|1|1|1
    do {
        typealias S = SpotifyWebAdProbe

        // ① 判定表。四个 data-testid 任一命中即广告(留冗余:Spotify 改掉其中一两个还能认)。
        expectEqual(S.parse("1|1|1|1"), .ad, "Spotify 广告判据: 真实广告样本(四条全中)判成广告")
        expectEqual(S.parse("0|0|0|0"), .song, "Spotify 广告判据: 真实歌曲样本(四条全灭)判成歌")
        expectEqual(S.parse("1|0|0|0"), .ad, "Spotify 广告判据: 只有 ad-controls 命中也算广告")
        expectEqual(S.parse("0|1|0|0"), .ad, "Spotify 广告判据: 只有广告副标题命中也算广告")
        expectEqual(S.parse("0|0|1|0"), .ad, "Spotify 广告判据: 只有倒计时命中也算广告")
        expectEqual(S.parse("0|0|0|1"), .ad, "Spotify 广告判据: 只有广告主链接命中也算广告")
        // 形状不认识一律 nil ——**不猜**,让调用方 fail-closed。
        for raw in ["NOTFOUND", "", "   \n", "1|0|0", "1|0|0|0|0", "1|x|0|0", "true|false|false|false"] {
            expectEqual(S.parse(raw), nil,
                        "Spotify 广告判据: 形状不认识时不做推断(\(raw.debugDescription))")
        }
        expectEqual(S.parse("\"1|1|1|1\""), .ad, "Spotify 广告判据: 脱掉 AppleScript 多包的引号")
        expectEqual(S.parse("\"0|0|0|0\"\n"), .song, "Spotify 广告判据: 脱引号+换行")

        // ② 出口。⚠️ 跟 YT Music 那个闸**少一个出口**:走到这条路上的播放本来就要被丢掉
        //    (歌手名为空),判定说"是歌"也不能让它变成一首可采纳的歌 —— 一首真歌不会没有
        //    歌手名,那多半是别的网页音频。所以这里只回答"要不要作为广告放行"。
        expectEqual(S.gate(verdict: .ad), .acceptAsAd, "Spotify 广告闸: 判定是广告 → 放行并标成广告")
        expectEqual(S.gate(verdict: .song), .reject, "Spotify 广告闸: 判定是歌 → 照旧丢掉")
        // fail-closed 的方向:最坏是"广告仍然让 UI 塌一下"(改动前的样子),不是"在真歌上
        // 贴广告标签"。
        expectEqual(S.gate(verdict: nil), .reject,
                    "Spotify 广告闸: 还没探到 → fail-closed,维持改动前的行为")

        // ③ 值不值得去问页面。⚠️ 这道门同时把 YT Music 探针的领地(artist 非空)挡在外面 ——
        //    不然配对了两个平台的浏览器每一轮要背两次 osascript 往返。
        expectEqual(S.fieldShapeNeedsProbe(title: "广告", artist: ""), true,
                    "Spotify 探测门槛: 标题非空 + 歌手为空(广告的真实形状)→ 值得问")
        expectEqual(S.fieldShapeNeedsProbe(title: "广告", artist: "   "), true,
                    "Spotify 探测门槛: 歌手全空白同样算空")
        expectEqual(S.fieldShapeNeedsProbe(title: "某首歌", artist: "周杰倫"), false,
                    "Spotify 探测门槛: 歌手非空 → 那是 YT Music 探针的领地,不重复发 AppleEvent")
        expectEqual(S.fieldShapeNeedsProbe(title: "", artist: ""), false,
                    "Spotify 探测门槛: 连标题都没有 → 没什么可确认的")
        expectEqual(S.fieldShapeNeedsProbe(title: nil, artist: nil), false,
                    "Spotify 探测门槛: 全 nil → 不问")

        // ④ ⚠️ JS 源码里不许出现双引号(整段要嵌进 AppleScript 的双引号字符串),也不许出现
        //    反斜杠(那是 AppleScript 那边的转义字符)。同 YT Music 那条纪律。
        expectEqual(S.probeJS.contains("\""), false, "Spotify 广告判据: JS 里不许有双引号")
        expectEqual(S.probeJS.contains("\\"), false, "Spotify 广告判据: JS 里不许有反斜杠")
        // ⚠️ **绝不能用子串匹配 `[data-testid*=ad]`**:歌曲态里就有 `add-button`(含 "ad"),
        //    会稳定误判成广告。这条机械闸钉住"只用精确匹配"。
        expectEqual(S.probeJS.contains("*="), false,
                    "Spotify 广告判据: 不许用 CSS 子串匹配(add-button 会把歌曲误判成广告)")
        for marker in ["now-playing-widget", "ad-controls", "context-item-info-ad-subtitle",
                       "ad-countdown-timer", "ad-link", "NOTFOUND"] {
            expectEqual(S.probeJS.contains(marker), true, "Spotify 广告判据: JS 里要有 \(marker)")
        }

        // ⑤ AppleScript 模板的文本契约,与 YT Music 那组同款。
        for family in [BrowserAutomationPermission.Family.chromium, .safari] {
            let s = S.buildAppleScript(bundleID: "com.apple.Safari", family: family)
            expectEqual(s.contains("tell application id \"com.apple.Safari\""), true,
                        "Spotify 广告判据/\(family): 用 tell application id")
            expectEqual(s.contains(S.hostMarker), true,
                        "Spotify 广告判据/\(family): 按 open.spotify.com 过滤标签页")
            expectEqual(s.components(separatedBy: "with timeout of").count - 1, 2,
                        "Spotify 广告判据/\(family): 两处执行点都套了 with timeout")
            expectEqual(s.contains("return \"NOTFOUND\""), true,
                        "Spotify 广告判据/\(family): 有兜底返回")
        }

        // ⑥ ⚠️ 两个探针必须共用**同一份** AppleScript 模板(2026-09-03 抽成
        //    `BrowserTabProbeScript`)。把各自的域名和 JS 抠掉之后,骨架必须逐字相同 ——
        //    谁把模板 fork 出去改一行,这条当场红。模板里每一行都是踩出来的(先扫当前标签页
        //    躲 Arc 休眠、with timeout 兜挂起、两种方言的注入命令不同名),漂开的代价是
        //    "某一个探针悄悄退化,而另一个还好好的"。
        func skeleton(_ script: String, host: String, js: String) -> String {
            script.replacingOccurrences(of: js, with: "<JS>")
                .replacingOccurrences(of: host, with: "<HOST>")
        }
        for family in [BrowserAutomationPermission.Family.chromium, .safari] {
            let yt = YouTubeMusicAdProbe.buildAppleScript(bundleID: "com.apple.Safari", family: family)
            let sp = S.buildAppleScript(bundleID: "com.apple.Safari", family: family)
            expectEqual(
                skeleton(yt, host: YouTubeMusicAdProbe.hostMarker, js: YouTubeMusicAdProbe.probeJS),
                skeleton(sp, host: S.hostMarker, js: S.probeJS),
                "Spotify 广告判据/\(family): 与 YT Music 探针共用同一份 AppleScript 模板")
        }
    }
    // ---- 「发现新播放器」判据(2026-08-22 用户报「没有通知机制」)----
    //
    // 两层:shouldOffer 是**卡片和通知共用**的(判据下沉到 Core 就是为了不让两边各抄一份),
    // shouldAnnounce 在它之上加通知专属的四条。任一条松了就会变成骚扰或者「点了没反应」。
    do {
        typealias A = UnknownPlayerAlert
        let now = Date()
        func offer(bundle: String = "com.google.Chrome", artist: String = "华晨宇",
                   album: String = "异类", age: TimeInterval = 0, auto: Bool = true,
                   accepted: Set<String> = []) -> Bool {
            A.shouldOffer(bundleID: bundle, artist: artist, album: album,
                          observedAt: now.addingTimeInterval(-age), isAutoDetect: auto, now: now,
                          isAccepted: { accepted.contains($0) })
        }
        // 用户报的原案
        expectEqual(offer(), true, "发现新播放器: 用户报的原案该提议信任")
        // ① 只在「自动识别」下
        expectEqual(offer(auto: false), false, "发现新播放器: 选了具体播放器时不提议")
        // ② 陈旧观察不提议(窗口跟设置页同一个数)
        expectEqual(offer(age: 14), true, "发现新播放器: 14 秒内算新鲜")
        expectEqual(offer(age: 16), false, "发现新播放器: 超过 15 秒的观察不提议")
        expectEqual(A.freshWindow, 15, "发现新播放器: 陈旧窗口必须是 15 秒(跟设置页对齐)")
        // ③ 歌手名和专辑名都非空,**trim 后**判空 —— 卡片原来写裸 isEmpty 是个既有 bug
        expectEqual(offer(album: ""), false, "发现新播放器: 专辑名空(YouTube 视频形状)不提议")
        expectEqual(offer(artist: ""), false, "发现新播放器: 歌手名空不提议")
        expectEqual(offer(album: "   "), false, "发现新播放器: 专辑名只有空白也算空(trim)")
        expectEqual(offer(artist: " \t "), false, "发现新播放器: 歌手名只有空白也算空(trim)")
        // ④ 已被接受的不提议
        expectEqual(offer(accepted: ["com.google.Chrome"]), false, "发现新播放器: 已信任的不提议")
        expectEqual(offer(bundle: ""), false, "发现新播放器: 空 bundle id 不提议")
        expectEqual(offer(bundle: "  "), false, "发现新播放器: 只有空白的 bundle id 不提议")
        expectEqual(offer(age: -5), true, "发现新播放器: 时钟回拨当新鲜,宁可多提示")
        // 内置五个播放器一律不提议(走真实的 isAccepted,名单传空)
        for player in PlaybackPlayer.allCases where player != .auto {
            expectEqual(A.shouldOffer(bundleID: player.bundleIdentifier, artist: "PRINCE",
                                      album: "Dirty Mind", observedAt: now, isAutoDetect: true,
                                      now: now,
                                      isAccepted: { TrustedPlayers.isAccepted($0, trusted: [:]) }),
                        false, "发现新播放器: 内置播放器不提议(\(player.rawValue))")
        }
        // ---- Safari 的媒体代理进程(2026-09-01)----
        // 用户实测撞上的断层:「网页播放器」卡里配对了 Safari(配对会把 com.apple.Safari 写进
        // 信任列表),可真播起来 MediaRemote 上报的是 com.apple.WebKit.GPU,不在名单里 →
        // 整条播放不被采纳,同时"发现未知播放器"卡还跳出来要用户再信任一个看不懂的 bundle id。
        do {
            let webkit = "com.apple.WebKit.GPU"
            let safari = "com.apple.Safari"
            expectEqual(TrustedPlayers.isAccepted(webkit, trusted: [safari: "Safari"]), true,
                        "Safari 代理: 信任了 Safari,它的 WebKit 媒体进程也该被采纳")
            expectEqual(TrustedPlayers.isAccepted(webkit, trusted: [:]), false,
                        "Safari 代理: 没信任 Safari 时不能凭空放行(别名不是白名单)")
            expectEqual(TrustedPlayers.isAccepted(webkit, trusted: ["com.google.Chrome": "Chrome"]),
                        false, "Safari 代理: 信任别的浏览器不能顺带放行 WebKit 进程")
            // 别名是单向的:信任代理进程不等于信任 Safari 本身
            expectEqual(TrustedPlayers.isAccepted(safari, trusted: [webkit: ""]), false,
                        "Safari 代理: 别名单向 —— 信任了代理进程不代表 Safari 本身被信任")
            expectEqual(TrustedPlayers.mediaProxyOwner(of: webkit), safari,
                        "Safari 代理: 宿主反查")
            expectEqual(TrustedPlayers.mediaProxyOwner(of: "com.google.Chrome"), nil,
                        "Safari 代理: Chromium 系报的是自己的 bundle id,不该在这张表里")
            // **跨层不变量**:别名一旦生效,"发现未知播放器"那张卡必须同时不再提议它 ——
            // 那张卡的判据就是 !isAccepted,两者绑在一起,将来任一边单独改都会红。
            expectEqual(A.shouldOffer(bundleID: webkit, artist: "Musiq Soulchild",
                                      album: "Juslisen", observedAt: now, isAutoDetect: true,
                                      now: now,
                                      isAccepted: { TrustedPlayers.isAccepted($0, trusted: [safari: "Safari"]) }),
                        false, "Safari 代理: 信任 Safari 之后不该再提议信任 WebKit 进程")
            expectEqual(A.shouldOffer(bundleID: webkit, artist: "Musiq Soulchild",
                                      album: "Juslisen", observedAt: now, isAutoDetect: true,
                                      now: now,
                                      isAccepted: { TrustedPlayers.isAccepted($0, trusted: [:]) }),
                        true, "Safari 代理: 没信任 Safari 时仍然该提议(兜底通路不能被别名吃掉)")

            // ---- TrustedPlayers.isTrusted(2026-09-01,播放器多选后新增)----
            // 只回答"信任"这一半(不含五个内置播放器),供"选中了具体播放器但没勾自动识别"
            // 这条路径用(MediaControlClient.fetchMultiSelectedSnapshot/artworkBundleIDMatches、
            // 以及 isAccepted 内部现在也委托给它,不重复实现)——最典型场景是「网页播放器」卡
            // 配对的浏览器,配对这个动作跟"选没选自动识别"是两件独立的事。
            expectEqual(TrustedPlayers.isTrusted("com.google.Chrome", trusted: ["com.google.Chrome": "Chrome"]),
                        true, "isTrusted: 信任列表里的 bundle id 该被认")
            expectEqual(TrustedPlayers.isTrusted("com.apple.Safari", trusted: [:]),
                        false, "isTrusted: 没信任过的 bundle id 不该被认")
            expectEqual(TrustedPlayers.isTrusted(PlaybackPlayer.qqMusic.bundleIdentifier, trusted: [:]),
                        false, "isTrusted: 只回答信任这一半,内置播放器不该被它认下来(那是 isAccepted 的职责)")
            expectEqual(TrustedPlayers.isTrusted(webkit, trusted: [safari: "Safari"]),
                        true, "isTrusted: 信任 Safari 之后,它的媒体代理进程也该经别名表被认")
            expectEqual(TrustedPlayers.isTrusted(nil, trusted: [safari: "Safari"]),
                        false, "isTrusted: nil bundle id 不该崩、也不该被认")
            expectEqual(TrustedPlayers.isTrusted("", trusted: [safari: "Safari"]),
                        false, "isTrusted: 空字符串 bundle id 不该被认")
        }

        // **跨层不变量**:凡是我们提议信任的,用户点下去一定真的生效 ——
        // 把判据和 TrustedPlayers.notASong 永久绑在一起,将来任何一边单独改都会红
        expectEqual(TrustedPlayers.notASong(bundleID: "com.google.Chrome", artist: "华晨宇",
                                            album: "异类",
                                            trusted: ["com.google.Chrome": ""]),
                    false, "发现新播放器: 提议信任的样本必须过得了 notASong 守卫")
        // 反向:Arc 放 YouTube 那份真实样本(artist=频道名、album 空)不该被提议
        expectEqual(offer(bundle: "company.thebrowser.Browser", artist: "Dream in reality",
                          album: ""), false, "发现新播放器: Arc YouTube 真实样本不提议")

        // ---- 第二层:通知专属 ----
        func announce(bundle: String = "com.google.Chrome", accepted: Set<String> = [],
                      hasName: Bool = true, stableFor: TimeInterval = 10, hits: Int = 5,
                      log: [String: A.AnnounceLog] = [:], at: Date = now) -> Bool {
            A.shouldAnnounce(bundleID: bundle, artist: "华晨宇", album: "异类", observedAt: at,
                             isAutoDetect: true, now: at,
                             isAccepted: { accepted.contains($0) },
                             hasDisplayName: hasName, stableFor: stableFor, stableHits: hits,
                             log: log)
        }
        expectEqual(announce(), true, "通知: 稳定 10 秒的新播放器该弹")
        // ⑤ 静音名单 —— 只影响"要不要弹",不影响"能不能信任"
        expectEqual(announce(bundle: "com.apple.podcasts"), false, "通知: 播客不弹(会被当歌打卡)")
        expectEqual(announce(bundle: "com.tencent.xinWeChat"), false, "通知: 微信不弹")
        expectEqual(A.mutedForAnnounce.contains("com.apple.Safari"), false,
                    "通知: Safari 不在静音名单(放网页音乐跟 Chrome 一样正当)")
        // 静音名单**不**收窄卡片那一层
        expectEqual(A.shouldOffer(bundleID: "com.apple.podcasts", artist: "某节目", album: "某季",
                                  observedAt: now, isAutoDetect: true, now: now,
                                  isAccepted: { _ in false }),
                    true, "通知: 静音名单里的 App 卡片照旧提议(想信任的人点得到)")
        // ⑥ 反查不到 App 名的不弹
        expectEqual(announce(hasName: false), false, "通知: 反查不到 App 名的不弹")
        // ⑦ 稳定性:时长和次数都要够
        expectEqual(announce(stableFor: 5.9), false, "通知: 稳定不足 6 秒不弹")
        expectEqual(announce(hits: 2), false, "通知: 观察不足 3 次不弹")
        expectEqual(announce(stableFor: 6, hits: 3), true, "通知: 刚好 6 秒 3 次就弹")
        expectEqual(A.stableWindow, 6, "通知: 稳定窗口 6 秒")
        expectEqual(A.stableHitsNeeded, 3, "通知: 稳定次数 3")
        // ⑧ 次数上限与冷却
        let day = A.announceCooldown
        expectEqual(announce(log: ["com.google.Chrome": .init(count: 1, lastAt: now)]), false,
                    "通知: 刚提醒过,冷却期内不再弹")
        expectEqual(announce(log: ["com.google.Chrome": .init(count: 1, lastAt: now - day)],
                             at: now), true, "通知: 隔了一天可以再弹")
        expectEqual(announce(log: ["com.google.Chrome": .init(count: 3, lastAt: now - day * 9)]),
                    false, "通知: 提醒满 3 次后永久停")
        expectEqual(A.maxAnnounces, 3, "通知: 上限 3 次(专注模式下可能一次都没看见)")
        expectEqual(announce(log: ["com.other.app": .init(count: 3, lastAt: now)]), true,
                    "通知: 别的 App 提醒满了不影响这个")
        // 已信任的一律不弹(第一层就挡住了)
        expectEqual(announce(accepted: ["com.google.Chrome"]), false, "通知: 已信任的不弹")
    }

    // ---- 「默认展示名单」≠「支持名单」(2026-09-01) ----
    // 用户拍板把 Arc 从「+」菜单的默认候选里拿掉,但**代码里对它的适配全部保留** —— 用户自己从
    // 「应用程序」里挑中它时要走完整的既有适配。这几条断言就是钉住这个区分:
    // 光看 `knownBrowserBundleIDs` 里没有 Arc 就去删 Arc 的适配,会当场红。
    do {
        let arc = "company.thebrowser.Browser"
        expectEqual(BrowserAutomationPermission.knownBrowserBundleIDs.contains(arc), false,
                    "浏览器默认名单: Arc 不该出现在「+」菜单的默认候选里")
        expectEqual(BrowserAutomationPermission.family(forBundleID: arc), .chromium,
                    "浏览器适配: Arc 的引擎族判定必须原样保留(不在默认名单 ≠ 不支持)")
        // Chrome / Edge / Safari 三个仍然默认展示 —— 免得"拿掉 Arc"被顺手扩大成"清空名单"。
        for id in ["com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari"] {
            expectEqual(BrowserAutomationPermission.knownBrowserBundleIDs.contains(id), true,
                        "浏览器默认名单: \(id) 应该仍在默认候选里")
        }
        // Firefox 这类没提供脚本命令的浏览器照旧判不出来 —— 反向锚点,证明上面那条不是"什么都返回 chromium"。
        expectEqual(BrowserAutomationPermission.family(forBundleID: "org.mozilla.firefox"), nil,
                    "浏览器适配: 没提供脚本命令的浏览器仍应判不出引擎族")
    }


    // 悬浮歌词字重(2026-09-02,用户要求"加一个控制字体粗细的功能配置")。
    //
    // ⚠️ 这一组的**第一条是兼容性不变量,不是风格检查**:加这个设置之前,四行的字重是四个硬编码
    // 值(主 bold=9 / 罗马音 medium=6 / 译文 regular=5 / 下一句 medium=6)。现在它们由用户选的
    // 那一档推导,默认档位必须逐个推回原来那四个数 —— 破了它,所有老用户的悬浮歌词升级后当场
    // 变样,而且没有任何报错、没有任何日志,只有"我的歌词怎么变细了"。
    do {
        print("\n== 悬浮歌词字重阶梯 ==")
        let base = OverlayFontWeight.bold  // = AppSettings.defaultOverlayFontWeight
        expectEqual(base.appKitWeight, 9, "字重: 默认档位就是改动前主歌词那个硬编码 bold")
        expectEqual(base.lighter(by: OverlayFontWeight.romanizationSteps).appKitWeight, 6,
                    "字重: 默认档位推出的罗马音必须等于改动前的 medium(6)")
        expectEqual(base.lighter(by: OverlayFontWeight.translationSteps).appKitWeight, 5,
                    "字重: 默认档位推出的译文必须等于改动前的 regular(5)")
        expectEqual(base.lighter(by: OverlayFontWeight.nextLinePreviewSteps).appKitWeight, 6,
                    "字重: 默认档位推出的下一句预览必须等于改动前的 medium(6)")

        // 阶梯本身:allCases 的顺序就是"从细到粗"这件事,lighter(by:) 直接按下标走。
        // 顺序被重排 = 静默改掉所有推导结果,所以这里钉的是**严格递增**,不是某几个具体值。
        let ladder = OverlayFontWeight.allCases
        expectEqual(ladder.count >= 4, true, "字重: 阶梯至少要有 4 档才谈得上推导")
        var strictlyIncreasing = true
        for i in 1..<ladder.count where ladder[i].appKitWeight <= ladder[i - 1].appKitWeight {
            strictlyIncreasing = false
        }
        expectEqual(strictlyIncreasing, true, "字重: allCases 必须按 AppKit 权重严格递增")
        expectEqual(ladder.first, .light, "字重: 最细那一档是 light")
        expectEqual(ladder.last, .heavy, "字重: 最粗那一档是 heavy")

        // 夹住:细到头就停在最细那一档,不绕回去、不越界。
        expectEqual(OverlayFontWeight.light.lighter(by: 3), .light, "字重: 细到头夹在最细档")
        expectEqual(OverlayFontWeight.regular.lighter(by: 9), .light, "字重: 夹住的是下标不是权重")
        // 反方向(传负数)不在用法之内,但也必须夹住而不是越界崩。
        expectEqual(OverlayFontWeight.heavy.lighter(by: -5), .heavy, "字重: 反方向同样夹在最粗档")
        expectEqual(OverlayFontWeight.bold.lighter(by: 0), .bold, "字重: 差 0 档就是自己")

        // 推导**永远不会比主行更粗** —— 这是"译文比主歌词还显眼"那个状态压根不存在的保证,
        // 而不是靠界面去防。三个档位差全为正,任何档位下都成立。
        for weight in ladder {
            for steps in [OverlayFontWeight.romanizationSteps,
                          OverlayFontWeight.translationSteps,
                          OverlayFontWeight.nextLinePreviewSteps] {
                expectEqual(weight.lighter(by: steps).appKitWeight <= weight.appKitWeight, true,
                            "字重: 派生行不能比主行粗(\(weight.rawValue) 细 \(steps) 档)")
            }
        }

        // rawValue 是持久化形态(np:overlayFontWeight),改名等于把老用户的选择静默丢回默认。
        for weight in ladder {
            expectEqual(OverlayFontWeight(rawValue: weight.rawValue), weight,
                        "字重: rawValue 必须能原样解回来: \(weight.rawValue)")
        }
        expectEqual(OverlayFontWeight(rawValue: "ultraLight"), nil,
                    "字重: 不认识的 rawValue 返回 nil(由调用方兜底到默认档)")
    }

    // MARK: - PlayerHealth(侧栏「播放器」警告徽标的判定,2026-09-03)
    do {
        typealias PH = PlayerHealth
        expectEqual(PH.warnings(.init(appleMusicSelected: true, automationDenied: false,
                                      collectorServiceEnabled: true, collectorRunning: true)),
                    [], "PlayerHealth: 一切正常不报")
        expectEqual(PH.warnings(.init(appleMusicSelected: true, automationDenied: true,
                                      collectorServiceEnabled: true, collectorRunning: true)),
                    [.automationDenied], "PlayerHealth: 选了 Apple Music 且权限被拒 → 报自动化")
        expectEqual(PH.warnings(.init(appleMusicSelected: false, automationDenied: true,
                                      collectorServiceEnabled: true, collectorRunning: true)),
                    [], "PlayerHealth: 没选 Apple Music 时权限被拒不报(那份权限与当前播放器无关)")
        expectEqual(PH.warnings(.init(appleMusicSelected: false, automationDenied: false,
                                      collectorServiceEnabled: true, collectorRunning: false)),
                    [.collectorNotRunning], "PlayerHealth: 服务开着却没在跑 → 报采集服务")
        expectEqual(PH.warnings(.init(appleMusicSelected: false, automationDenied: false,
                                      collectorServiceEnabled: false, collectorRunning: false)),
                    [], "PlayerHealth: 用户自己关掉服务不算故障")
        expectEqual(PH.warnings(.init(appleMusicSelected: true, automationDenied: true,
                                      collectorServiceEnabled: true, collectorRunning: false)),
                    [.collectorNotRunning, .automationDenied], "PlayerHealth: 两条都中时采集服务排前面")
    }
}

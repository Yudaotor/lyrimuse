import Foundation

/// 「发现新播放器」的判据 —— 纯函数,这件事唯一的真相来源。
///
/// 2026-08-22 用户报:「识别到新的播放器,但我自己不知道要去这里信任,目前没有一个通知机制」。
/// 在这之前唯一的发现路径是设置页那张卡,而它**只在那个播放器此刻正在报 Now Playing 时**
/// 才出现 —— 不主动打开设置页就永远看不到。
///
/// ## 为什么判据要下沉到这里
///
/// 原来那套门槛是写在 View 的 `if` 里的(SettingsView.unknownPlayerCard)。通知那条路必然要
/// 再抄一份 —— **抄漏是必然的**,而抄漏的后果很难看:通知让你去信任,点进设置页那张卡却不在;
/// 或者反过来。所以拆成两层,两边都调这里:
///  - `shouldOffer`:**卡片和通知共用**。回答"这个观察值该不该提议信任"。
///  - `shouldAnnounce`:通知**专属**的额外门槛。通知是我们主动打扰用户,门槛该比卡片高。
public enum UnknownPlayerAlert {
    /// 观察陈旧判定的窗口。停播之后那笔观察还挂在 MediaControlClient 的静态变量上
    /// (media-control 输出 null 时 recordUngatedNowPlaying 压根不会被调到),不过滤就会
    /// 为一个早就不放了的 App 提议信任。15 秒 = 主轮询周期(2s)的七倍多,容得下一次卡顿。
    public static let freshWindow: TimeInterval = 15

    // MARK: - 第一层:卡片和通知共用

    /// 这个观察值该不该提议信任。四条:
    ///  1. 只在「自动识别」下 —— 选了具体播放器时,信任名单压根不参与判断
    ///     (那条路走 fetchMediaControlSnapshot(expectedBundleID:),只认那一个 bundle id)。
    ///     漏了这条的体验是:点了信任、列表里多一条、行为一点没变、下次还提示;
    ///  2. 观察不陈旧(freshWindow);
    ///  3. 歌手名**和**专辑名都非空 —— 跟 TrustedPlayers.notASong 同判据(**同样 trim 后判空**)。
    ///     少了这条会让用户去点一个必定没反应的按钮:YouTube 视频就是 artist 有(频道名)、
    ///     album 恒空这个形状,信任之后照样被那道守卫两侧都丢掉,零变化;
    ///  4. 还没被接受 —— 内置五个 + 已信任的都不提。
    public static func shouldOffer(
        bundleID: String, artist: String, album: String, observedAt: Date,
        isAutoDetect: Bool, now: Date, isAccepted: (String) -> Bool
    ) -> Bool {
        guard isAutoDetect else { return false }
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        // 负数(时钟回拨/观察时刻在未来)当"新鲜" —— 宁可多提示一次也别静默
        guard now.timeIntervalSince(observedAt) < freshWindow else { return false }
        // ⚠️ trim 后判空,跟 TrustedPlayers.notASong 完全一致。卡片原来写的是裸 isEmpty,
        // 于是 album = " " 的播放能过卡片、过不了守卫 —— 那是个既有 bug,这次一并抹平。
        guard !artist.trimmingCharacters(in: .whitespaces).isEmpty,
              !album.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !isAccepted(id)
    }

    // MARK: - 第二层:通知专属

    /// **只影响"要不要主动弹通知",不影响"能不能信任"**的静音名单。
    ///
    /// 这些 App 会报 Now Playing、而且能过 artist/album 都非空那道门槛,但它们不是音乐播放器:
    /// 播客(artist=节目名、album 常常非空)一旦被信任就会被当歌打卡进 Last.fm/ListenBrainz
    /// 的**永久历史**;微信语音/视频号是这台机器上真正"天天来一次"的那个。
    ///
    /// ⚠️ 刻意**不**写成"整个 com.apple.* 都静音":Safari 放网页音乐跟 Chrome 一样正当,
    /// 一刀切会把它也埋掉。只列点名的。
    /// ⚠️ 设置页那张卡**不**受这份名单影响 —— 真想信任播客的人照样点得到,这正是
    /// "卡片保留作兜底"的价值。
    public static let mutedForAnnounce: Set<String> = [
        "com.apple.podcasts", "com.apple.TV", "com.apple.iBooksX", "com.apple.news",
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.apple.QuickTimePlayerX",
        "com.apple.Preview", "com.apple.Photos", "com.apple.VoiceMemos",
        "com.apple.WebKit.GPU", "com.apple.controlcenter",
        "com.tencent.xinWeChat",
    ]

    /// 提醒次数上限与最短间隔。
    ///
    /// 为什么不是"一辈子只提醒一次":实测这台机器**现在就开着专注模式**
    /// (com.apple.focus.work 的 assertion 从 01:36 起没有失效记录),还有 App 启动触发的
    /// DND 和每天 00:00 的定时 DND。DND 下横幅根本不弹、静默进通知中心,被一次
    /// 「清除全部」就永久丢失 —— "只提醒一次"在这种机器上等于没提醒。
    /// 所以给三次机会、每次至少隔一天;信任成功后 shouldOffer 天然不再成立,自动停。
    public static let maxAnnounces = 3
    public static let announceCooldown: TimeInterval = 24 * 3600

    /// 已经提醒过的记录:bundle id → (提醒过几次, 最后一次是什么时候)。
    public struct AnnounceLog: Codable, Equatable, Sendable {
        public var count: Int
        public var lastAt: Date
        public init(count: Int, lastAt: Date) { self.count = count; self.lastAt = lastAt }
    }

    /// 该不该**弹通知**。第一层全过之后再加四条:
    ///  5. 不在静音名单里;
    ///  6. `appDisplayName` 反查得到 —— 反查不到 App 名(`com.apple.WebKit.GPU` 这种)
    ///     说明它不是用户能理解的东西,通知标题只能摆一串 bundle id,别弹;
    ///  7. 稳定性:同一个 bundle id 连续被观察到够久。实测这台机器上焦点抖动是常态
    ///     (12 分钟里 4 组亚秒级往返 Music ⇄ Chrome),不设这道门会为一个只抢了两秒
    ///     焦点的 App 烧掉它那几次提醒机会;
    ///  8. 次数与冷却(见 maxAnnounces / announceCooldown)。
    public static func shouldAnnounce(
        bundleID: String, artist: String, album: String, observedAt: Date,
        isAutoDetect: Bool, now: Date, isAccepted: (String) -> Bool,
        hasDisplayName: Bool, stableFor: TimeInterval, stableHits: Int,
        log: [String: AnnounceLog]
    ) -> Bool {
        guard shouldOffer(bundleID: bundleID, artist: artist, album: album,
                          observedAt: observedAt, isAutoDetect: isAutoDetect, now: now,
                          isAccepted: isAccepted) else { return false }
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !mutedForAnnounce.contains(id) else { return false }
        guard hasDisplayName else { return false }
        guard stableFor >= stableWindow, stableHits >= stableHitsNeeded else { return false }
        guard let seen = log[id] else { return true }
        guard seen.count < maxAnnounces else { return false }
        return now.timeIntervalSince(seen.lastAt) >= announceCooldown
    }

    /// 稳定性门槛:同一个 bundle id 至少连续被观察到这么久、这么多次。
    /// 两条都要 —— 次数单独不够(事件密集时三次可能只跨 0.3 秒),时长单独也不够
    /// (中间断过再回来不算连续,断了就由调用方清零重数)。
    public static let stableWindow: TimeInterval = 6
    public static let stableHitsNeeded = 3
}

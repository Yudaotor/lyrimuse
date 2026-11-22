import Foundation

/// 浏览器里 YouTube Music 网页版的随机、循环、点赞、音量。都读写它自己页面上的东西,跟界面语言无关:
/// - 循环:播放条 `ytmusic-player-bar` 的 `repeat-mode` 属性(NONE / ALL / ONE);写入用脚本点它那颗循环键
///   (`yt-icon-button.repeat`),点一下立即翻到下一档(关 → 全部 → 单曲 → 关)。
/// - 随机:播放条的 `shuffle-on` 属性(有就是开着,能保持);写入调播放条的 `queue.shuffle()`(切换,跟 Pear Desktop 接口
///   做的一样),没有这个方法时点随机键(`yt-icon-button.shuffle`)。随机和循环合成一档的规则同 Kaset(02 章决策 230)。
/// - 点赞:播放条里 `ytmusic-like-button-renderer` 的 `like-status`(LIKE / DISLIKE / INDIFFERENT);写入点它的「赞」键。
///   踩过(DISLIKE)算没赞,点一下变成赞。
/// - 音量:它自己的音量条 `#volume-slider`(0~100,按听感换算,跟它界面上显示的一致);写入改值再发 change 事件,
///   播放器音量和它记住的音量一起变。直接调播放器的 `setVolume` 只改实际音量、音量条和记住的值不变,换歌会被改回去。
///
/// 音量条的 `value` 和播放条的 `queue` 是页面挂在元素上的属性,Chromium 系脚本接口的隔离环境里看不见(读出 undefined,
/// 写进去的只是隔离环境里的普通属性,页面音量不变):这两样经 `BrowserTabProbeScript.inPageWorld` 读写,其余照旧在当前环境
/// 做(02 章决策 286)。
///
/// 新版播放条(`ytmusic-miniplayer`,页面上没有 `ytmusic-player-bar`)上同样四样,有经典播放条时一律只走上面那套(02 章决策 287):
/// - 循环、随机:页面状态 `ytmusic-app` 的 `getState().queue`(`repeatMode`、`shuffleEnabled`,经 `inPageWorld` 读,`miniModesJS`);
///   写入点循环键 / 随机键(`.ytmusicPlayerControlsRepeatButton button` / `.ytmusicPlayerControlsShuffleButton button`)。
///   键上的 `aria-pressed` 要等页面重画才跟上,连点第二下会被页面按旧状态处理掉,所以一次脚本只点一下循环键,
///   没到目标回 `STEP:`,由 `setMode` 隔 `repeatStepGap` 再发一次。
/// - 点赞:操作栏里 `like-button-view-model` 的按钮,`aria-pressed` 为 true 算赞了;不登录时操作栏有时不渲染,渲染了点「赞」只弹登录框。
/// - 音量:`slider-shape input#slider`,原生 `<input>` 的 `value` 两种环境都读写得到;写入改值再发 input、change 事件。
///
/// 注入走 `BrowserTabProbeScript`(跟广告探针同一份模板、同一个 JavaScript 授权);只在这个浏览器配对过 YouTube Music
/// 时用。开着几个 YouTube Music 标签页时认在放的那一页:写入先只动在放的那页,一页都没在放(全暂停着)再动第一页。
/// 读和写都只认页面上正放着当前这一首的标签页(`YouTubeMusicAdProbe.titleGuardJS`,标题对不上回 `NOTFOUND`、模板接着找):
/// 「是哪个网页平台」是配对推断(`BrowserPositionProbe.resolvePlayingPlatformID`),同一浏览器里放着普通 www.youtube.com
/// 视频、另一个窗口开着暂停的 YouTube Music 页时也会推成 YouTube Music,不比标题就会把赞、音量、循环写到那一页上。
/// 见 07 章决策 136、138,02 章决策 150。
public enum YouTubeMusicWebControls {
    public static let platformID = "youtubeMusic"
    public static let modeOptions: MusicPlaybackController.PlaybackModeOptions = .all
    /// 切完随机到读回之间等多久:`shuffle-on` 不一定在调用返回时就翻过来。
    static let shuffleSettle: TimeInterval = 0.6
    /// 新版播放条上两次点循环键之间至少隔多久(页面重画完才认下一下)。
    public static let repeatStepGap: TimeInterval = 0.3
    /// 新版播放条上循环键最多点几次(关 → 全部 → 单曲 → 关,到任一档最多两下)。
    public static let maxRepeatSteps = 3
    static let eventTimeoutSeconds = 4
    static let processTimeout: TimeInterval = 6

    /// 往哪个浏览器注入:浏览器本体的 bundle id(Safari 报的 `com.apple.WebKit.GPU` 已换成 `com.apple.Safari`)、脚本方言,
    /// 和当前这一首的标题(只动页面上放着这个标题的标签页)。
    public struct Target: Equatable, Sendable {
        public let bundleID: String
        public let family: BrowserAutomationPermission.Family
        public let title: String
    }

    /// 一次读回的几样;哪样读不懂就是 nil。`mode` 由随机开关和循环档合成(`kasetPlaybackMode`)。
    public struct State: Equatable, Sendable {
        public let mode: MusicPlaybackController.MusicPlaybackMode?
        public let liked: Bool?
        public let volume: Int?
        public let shuffling: Bool?
        public let repeatMode: String?

        public init(mode: MusicPlaybackController.MusicPlaybackMode?, liked: Bool?, volume: Int?,
                    shuffling: Bool? = nil, repeatMode: String? = nil) {
            self.mode = mode
            self.liked = liked
            self.volume = volume
            self.shuffling = shuffling
            self.repeatMode = repeatMode
        }
    }

    /// `repeat-mode` 的值 → 档位。
    public static func mode(fromAttribute value: String) -> MusicPlaybackController.MusicPlaybackMode? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "NONE": return .list
        case "ALL": return .repeatAll
        case "ONE": return .repeatOne
        default: return nil
        }
    }

    /// 随机开关 + `repeat-mode` → 档位(单曲循环优先,其次随机)。任一项读不到为 nil。
    public static func mode(shuffling: Bool?, repeatAttribute: String?) -> MusicPlaybackController.MusicPlaybackMode? {
        let repeating: String?
        switch repeatAttribute.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }) {
        case "NONE": repeating = "off"
        case "ALL": repeating = "all"
        case "ONE": repeating = "one"
        default: repeating = nil
        }
        return MusicPlaybackController.kasetPlaybackMode(shuffling: shuffling, repeating: repeating)
    }

    /// `like-status` → 赞了没有(踩过算没赞)。
    public static func liked(fromStatus value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "LIKE": return true
        case "INDIFFERENT", "DISLIKE": return false
        default: return nil
        }
    }

    /// 读四样,回 `STATE:<repeat-mode>|<like-status>|<音量条>|<随机 1/0>`;暂停的标签页带 `PAUSED:` 前缀,模板据此先找在放的那一页。
    /// 页面上放的不是 `title` 回 `NOTFOUND`。不许出现双引号(见 `BrowserTabProbeScript`)。
    public static func readJS(title: String) -> String {
        "(function(){" + titleGuardPrologue(title) + """
    var out;\
    if (bar) {\
    var lk = bar.querySelector('ytmusic-like-button-renderer');\
    var s = document.querySelector('#volume-slider');\
    var vol = s ? \(volumeReadJS) : '';\
    if (vol === 'NOTFOUND') vol = '';\
    out = 'STATE:' + (bar.getAttribute('repeat-mode') || '') + '|' + (lk ? (lk.getAttribute('like-status') || '') : '') + '|' + vol + '|' + (bar.getAttribute('shuffle-on') !== null ? '1' : '0');\
    } else {\
    var mm = \(miniModesJS).split(',');\
    var rb = mini.querySelector('.ytmusicPlayerControlsRepeatButton button'), sb = mini.querySelector('.ytmusicPlayerControlsShuffleButton button');\
    var lb = mini.querySelector('like-button-view-model button'), lp = lb ? lb.getAttribute('aria-pressed') : null;\
    var sl = mini.querySelector('slider-shape input#slider');\
    var rep = mm.length === 2 ? mm[0] : ((rb && rb.getAttribute('aria-pressed') === 'false') ? 'NONE' : '');\
    var shuf = mm.length === 2 ? mm[1] : (sb ? (sb.getAttribute('aria-pressed') === 'true' ? '1' : '0') : '');\
    out = 'STATE:' + rep + '|' + (lp === 'true' ? 'LIKE' : (lp === 'false' ? 'INDIFFERENT' : '')) + '|' + (sl ? String(sl.value) : '') + '|' + shuf;\
    }\
    var v = document.querySelector('video');\
    return (v && v.paused) ? 'PAUSED:' + out : out;\
    })()
    """
    }

    /// 音量条的 `value`(字符串),在看得见它的环境里读;没有音量条回空串。
    static let volumeReadJS = BrowserTabProbeScript.inPageWorld(
        core: "function(){ var s = document.querySelector('#volume-slider'); return s ? String(s.value) : ''; }",
        pageVisible: YouTubeMusicAdProbe.pageWorldVisibleJS)

    /// 播放条有 `queue.shuffle()` 就在看得见它的环境里调、回 `OK`,没有回 `NONE`(调用方退回点随机键)。
    static let queueShuffleJS = BrowserTabProbeScript.inPageWorld(
        core: "function(){ var b = document.querySelector('ytmusic-player-bar'); if (b && b.queue && b.queue.shuffle) { b.queue.shuffle(); return 'OK'; } return 'NONE'; }",
        pageVisible: YouTubeMusicAdProbe.pageWorldVisibleJS)

    /// 新版播放条的循环档和随机开关:页面状态里的 `queue.repeatMode`、`queue.shuffleEnabled`,回 `<档>,<1/0>`,读不到回空串
    /// (经 `inPageWorld` 进不了主环境时回 `NOTFOUND`)。调用方按逗号切,不是两段就当读不到。
    static let miniModesJS = BrowserTabProbeScript.inPageWorld(
        core: "function(){ var a = document.querySelector('ytmusic-app'); var st = (a && a.getState) ? a.getState() : null; var q = st && st.queue; " +
            "return (q && q.repeatMode) ? String(q.repeatMode) + ',' + (q.shuffleEnabled ? '1' : '0') : ''; }",
        pageVisible: YouTubeMusicAdProbe.pageWorldVisibleJS)

    /// 读写共用的头:找播放条(经典的 `bar`,没有时找新版的 `mini`,两个都没有回 `NOTFOUND`),再核对页面上放的是不是 `title`
    /// (对不上回 `NOTFOUND`)。
    static func titleGuardPrologue(_ title: String) -> String {
        """
        var bar = document.querySelector('ytmusic-player-bar');\
        var mini = bar ? null : document.querySelector('ytmusic-miniplayer');\
        if (!bar && !mini) return 'NOTFOUND';\
        \(YouTubeMusicAdProbe.titleGuard(expecting: title))
        """
    }

    /// 写入脚本的公共头:找播放条、核对标题;`force` 为 false 时暂停的标签页不动、回 `PAUSED:SKIP`,让模板接着找在放的那页。
    /// 第二轮(`force` 为 true)动的是第一个**放着这一首**的暂停页,不是随便哪个暂停页。
    static func setPrologue(title: String, force: Bool) -> String {
        titleGuardPrologue(title) + """
        var v = document.querySelector('video');\
        if (\(force ? "false" : "true") && v && v.paused) return 'PAUSED:SKIP';
        """
    }

    /// 切到某一档:随机开关跟目标不一样就切一下,再点循环键直到到目标(最多三下),回 `SET:<repeat-mode>`。语义同 Kaset
    /// (`kasetPlaybackModeScript`):随机和循环互斥,「列表」「随机」只把单曲循环关掉,列表循环开着就留着。随机开关可能
    /// 晚一拍才翻,到没到由调用方隔 `shuffleSettle` 读回核对。
    /// 新版播放条上循环键只点一下,还没到目标回 `STEP:<档>`(见类头注);读不到页面状态回 `NOTFOUND`。
    public static func setModeJS(_ mode: MusicPlaybackController.MusicPlaybackMode, title: String, force: Bool) -> String {
        let target: String
        switch mode {
        case .list, .shuffle: target = "(m === 'ONE' ? 'NONE' : m)"
        case .repeatAll: target = "'ALL'"
        case .repeatOne: target = "'ONE'"
        }
        return "(function(){" + setPrologue(title: title, force: force) + """
        var want = \(mode == .shuffle ? "true" : "false");\
        if (!bar) {\
        var mm = \(miniModesJS).split(',');\
        var rb = mini.querySelector('.ytmusicPlayerControlsRepeatButton button'), sb = mini.querySelector('.ytmusicPlayerControlsShuffleButton button');\
        if (mm.length !== 2 || !rb) return 'NOTFOUND';\
        if ((mm[1] === '1') !== want) { if (!sb) return 'NOTFOUND'; sb.click(); }\
        var m = mm[0];\
        var target = \(target);\
        if (m !== target) { rb.click(); mm = \(miniModesJS).split(','); m = mm.length === 2 ? mm[0] : ''; }\
        return (m === target ? 'SET:' : 'STEP:') + m;\
        }\
        var b = bar.querySelector('yt-icon-button.repeat');\
        if (!b) return 'NOTFOUND';\
        if ((bar.getAttribute('shuffle-on') !== null) !== want) {\
        if (\(queueShuffleJS) !== 'OK') {\
        var sb = bar.querySelector('yt-icon-button.shuffle');\
        if (!sb) return 'NOTFOUND';\
        sb.click(); }\
        }\
        var m = bar.getAttribute('repeat-mode') || '';\
        var target = \(target);\
        for (var i = 0; i < 3 && m !== target; i++) { b.click(); m = bar.getAttribute('repeat-mode') || ''; }\
        return 'SET:' + m;\
        })()
        """
    }

    /// 赞 / 取消赞:跟目标不一样才点「赞」键,回 `SET:<like-status>`。
    /// 只认 `#button-shape-like`,找不到回 `NOTFOUND`;别拿渲染器里第一个按钮兜底,那是「踩」。
    /// 新版播放条只认 `like-button-view-model` 里的按钮(「踩」是另一个元素),`aria-pressed` 读不懂回 `NOTFOUND`;
    /// 点完回的是点之前的状态(页面重画后才变),到没到由 `setLiked` 读回核对。
    public static func setLikeJS(liked: Bool, title: String, force: Bool) -> String {
        "(function(){" + setPrologue(title: title, force: force) + """
        if (!bar) {\
        var lb = mini.querySelector('like-button-view-model button'), lp = lb ? lb.getAttribute('aria-pressed') : null;\
        if (lp !== 'true' && lp !== 'false') return 'NOTFOUND';\
        if ((lp === 'true') !== \(liked ? "true" : "false")) lb.click();\
        return 'SET:' + ((lb.getAttribute('aria-pressed') === 'true') ? 'LIKE' : 'INDIFFERENT');\
        }\
        var lk = bar.querySelector('ytmusic-like-button-renderer');\
        if (!lk) return 'NOTFOUND';\
        var b = lk.querySelector('#button-shape-like button');\
        if (!b) return 'NOTFOUND';\
        if ((lk.getAttribute('like-status') === 'LIKE') !== \(liked ? "true" : "false")) b.click();\
        return 'SET:' + (lk.getAttribute('like-status') || '');\
        })()
        """
    }

    /// 改音量条并发 change 事件,回 `SET:<音量条>`。改值和发事件都在看得见音量条 `value` 的环境里做,到不了那里回 `NOTFOUND`。
    /// 新版播放条的音量条是原生 `<input>`,在当前环境里改值、发 input 和 change。
    public static func setVolumeJS(_ value: Int, title: String, force: Bool) -> String {
        let clamped = min(100, max(0, value))
        let write = BrowserTabProbeScript.inPageWorld(
            core: "function(){ var s = document.querySelector('#volume-slider'); if (!s) return 'NOTFOUND'; s.value = " +
                "\(clamped); s.dispatchEvent(new Event('change', {bubbles: true})); return 'SET:' + String(s.value); }",
            pageVisible: YouTubeMusicAdProbe.pageWorldVisibleJS)
        return "(function(){" + setPrologue(title: title, force: force) + """
        if (!bar) {\
        var sl = mini.querySelector('slider-shape input#slider');\
        if (!sl) return 'NOTFOUND';\
        sl.value = \(clamped);\
        sl.dispatchEvent(new Event('input', {bubbles: true}));\
        sl.dispatchEvent(new Event('change', {bubbles: true}));\
        return 'SET:' + String(sl.value);\
        }\
        if (!document.querySelector('#volume-slider')) return 'NOTFOUND';\
        return \(write);\
        })()
        """
    }

    public static func parseRead(_ raw: String) -> State? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("STATE:") else { return nil }
        let parts = s.dropFirst(6).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        let shuffling: Bool? = parts[3] == "1" ? true : (parts[3] == "0" ? false : nil)
        let repeatMode = mode(fromAttribute: parts[0]) == nil ? nil : parts[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return State(mode: mode(shuffling: shuffling, repeatAttribute: repeatMode), liked: liked(fromStatus: parts[1]),
                     volume: Double(parts[2]).map { Int($0.rounded()) }, shuffling: shuffling, repeatMode: repeatMode)
    }

    public enum SetOutcome: Equatable, Sendable {
        /// 动过了,`SET:` 后面那个值(到没到目标调用方自己比)。
        case set(String)
        /// 新版播放条上点了一下循环键、还没到目标,`STEP:` 后面是点完的那一档;隔一会儿再发同一段脚本。
        case step(String)
        /// 只找到暂停着的页面、没动。
        case skipped
        case failed
    }

    public static func parseSet(_ raw: String) -> SetOutcome {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("SET:") { return .set(String(s.dropFirst(4))) }
        if s.hasPrefix("STEP:") { return .step(String(s.dropFirst(5))) }
        if s == "SKIP" { return .skipped }
        return .failed
    }

    /// 当前这条播放要不要走这里:播放器是浏览器、认出来在放 YouTube Music、这个浏览器配对过它,而且有标题可比。
    /// `isPaired` 收的是报上来的原值(网页应用算配对了自己那个平台,见 `BrowserPositionProbe.isPaired`),脚本发给宿主。
    public static func target(reportedBundleID: String?, webPlatformID: String?, title: String?,
                              isPaired: (String) -> Bool) -> Target? {
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard webPlatformID == platformID, !title.isEmpty, let reportedBundleID,
              let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID), !host.isEmpty,
              let family = BrowserAutomationPermission.family(forBundleID: host),
              isPaired(reportedBundleID) else { return nil }
        return Target(bundleID: host, family: family, title: title)
    }

    /// 读三样;页面没找到、读不懂为 nil。会阻塞到 osascript 结束,别在主线程调。
    public static func readState(_ target: Target) -> State? {
        run(target, js: readJS(title: target.title)).flatMap(parseRead)
    }

    /// 切到某一档,隔 `shuffleSettle` 读回随机开关和循环档,合成的档位就是要的那一档才回 true(从列表循环要「列表」时列表循环
    /// 按规则留着,回 false,调用方据此回读纠正显示)。会阻塞,别在主线程调。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode, _ target: Target) -> Bool {
        let outcome = stepUntilSet(sleep: { Thread.sleep(forTimeInterval: $0) }) {
            write(target) { setModeJS(mode, title: target.title, force: $0) }
        }
        guard case .set = outcome else { return false }
        Thread.sleep(forTimeInterval: shuffleSettle)
        return readState(target)?.mode == mode
    }

    /// 发一次 `write`,回 `step`(新版播放条只点了一下循环键)就隔 `repeatStepGap` 再发,最多共发 `maxRepeatSteps` 次,回最后一次的结果。
    /// 公开只为 selftest。
    public static func stepUntilSet(sleep: (TimeInterval) -> Void, _ write: () -> SetOutcome) -> SetOutcome {
        var outcome = write()
        for _ in 1..<maxRepeatSteps {
            guard case .step = outcome else { break }
            sleep(repeatStepGap)
            outcome = write()
        }
        return outcome
    }

    /// 赞 / 取消赞,返回到没到。会阻塞,别在主线程调。
    /// 回的状态还没跟上(新版播放条点完要等页面重画)时隔 `shuffleSettle` 读回再比。
    public static func setLiked(_ value: Bool, _ target: Target) -> Bool {
        guard case .set(let status) = write(target, js: { setLikeJS(liked: value, title: target.title, force: $0) }) else { return false }
        if liked(fromStatus: status) == value { return true }
        Thread.sleep(forTimeInterval: shuffleSettle)
        return readState(target)?.liked == value
    }

    /// 设音量(0~100),返回写没写进去。会阻塞,别在主线程调。
    public static func setVolume(_ value: Int, _ target: Target) -> Bool {
        if case .set = write(target, js: { setVolumeJS(value, title: target.title, force: $0) }) { return true }
        return false
    }

    /// 先只动在放的那页,一页都没在放再动第一个暂停页;两轮都只认放着 `target.title` 的页面。回动过的结果(`set` / `step`),
    /// 没写成为 `failed`。
    private static func write(_ target: Target, js: (Bool) -> String) -> SetOutcome {
        for force in [false, true] {
            guard let raw = run(target, js: js(force)) else { return .failed }
            switch parseSet(raw) {
            case .skipped: continue
            case let outcome: return outcome
            }
        }
        return .failed
    }

    private static func run(_ target: Target, js: String) -> String? {
        BrowserTabProbeScript.run(bundleID: target.bundleID, family: target.family, hostMarker: YouTubeMusicAdProbe.hostMarker,
                                  js: js, eventTimeoutSeconds: eventTimeoutSeconds, processTimeout: processTimeout,
                                  label: "ytmusic-controls")
    }
}

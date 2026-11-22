import Foundation
import JavaScriptCore
import LyrimuseCore

/// Chromium 系的 AppleScript `execute javascript` 跑在隔离环境里,页面挂在元素上的 JS 属性看不见(02 章决策 285、286)。
/// 这里在 JavaScriptCore 里搭两种环境的假页面,真跑注入的那几段 JS:YouTube Music 进度探针的视频身份、网页版控制的音量与随机、
/// Spotify 网页版进度探针的播放器状态和待播队列,以及 YouTube Music 新版播放条(`ytmusic-miniplayer`)上的探针与网页版控制。
///
/// 假页面的规矩:`safari` 为真时整段跑在主环境(Safari);否则跑在隔离环境,只有 `__runMain` 跑起来的代码(插进页面的内联脚本、
/// `blob:` 外链脚本、主环境里登记的事件监听)看得见页面属性。内联脚本要带对 nonce(页面有 nonce 时)、内容是 Trusted Types 包过的
/// (页面要求时)才跑;`blob:` 脚本先排队,`__flushBlobs()` 时才在主环境跑(浏览器里是异步的)。
func pageWorldReadTests() {
    spotifyQueueAcrossWorlds()
    spotifyProbeAcrossWorlds()
    spotifyWidgetV2AcrossWorlds()
    youTubeMusicProbeIdentityAcrossWorlds()
    youTubeMusicControlsAcrossWorlds()
    youTubeMusicMiniplayerAcrossWorlds()
    youTubeMusicMiniplayerStepLoop()
    pageWorldGuard()
}

/// 往浏览器标签页里注入的每段 JS:出现页面挂在元素 / 窗口上的那几样(组件树、播放器方法、Polymer 属性、页面全局)时,
/// 这段 JS 里必须有 `inPageWorld` 的包装,不然 Chromium 系上读出 undefined、看着像页面里没有。新加注入脚本时加进这张表。
private func pageWorldGuard() {
    let title = "Song"
    let scripts: [(String, String)] = [
        ("YouTube Music 进度探针", BrowserPositionProbe.filledSiteScript(platformID: "youtubeMusic", expectedDuration: 200) ?? ""),
        ("Spotify 网页版进度探针", BrowserPositionProbe.filledSiteScript(platformID: "spotifyWeb", expectedDuration: 200) ?? ""),
        ("YouTube Music 队列", PlayerQueryServer.youTubeMusicQueueJS),
        ("Spotify 网页版队列", PlayerQueryServer.spotifyWebQueueJS),
        ("网页版读回", YouTubeMusicWebControls.readJS(title: title)),
        ("网页版音量", YouTubeMusicWebControls.setVolumeJS(50, title: title, force: true)),
        ("网页版随机", YouTubeMusicWebControls.setModeJS(.shuffle, title: title, force: true)),
        ("网页版点赞", YouTubeMusicWebControls.setLikeJS(liked: true, title: title, force: true)),
        ("YouTube Music 广告探针", YouTubeMusicAdProbe.probeJS(title: title, playing: true)),
        ("Spotify 网页版广告探针", SpotifyWebAdProbe.probeJS),
        ("跳广告门槛", YouTubeMusicAdSkipper.skipJS),
        ("跳广告复核", YouTubeMusicAdSkipper.verifyJS),
        ("广告标签页", BrowserTabFocus.adTabJS),
    ]
    let pageOnly = ["__reactFiber", "memoizedProps", "playerAPI", "getPlayerResponse", "ytcfg", ".queue", ".data"]
    for (name, js) in scripts {
        let hits = pageOnly.filter { js.contains($0) }
        expectEqual(hits.isEmpty || js.contains(BrowserTabProbeScript.pageWorldAttribute), true,
                    "\(name): 读页面属性(\(hits.joined(separator: " ")))要经 inPageWorld")
    }
}

private let pageWorldKit = #"""
var safari = false, mainWorld = false;
function inMain() { return safari || mainWorld; }
var __kit = { inline: true, nonce: 'page-nonce', tt: true, blob: true, inlineRan: 0, blobAttempts: 0, blobsRan: 0, appended: 0, pending: [], listeners: [] };
var __attrs = {};
var __blobs = {}, __blobSeq = 0;
function __runMain(text) { var was = mainWorld; mainWorld = true; try { (0, eval)(text); } finally { mainWorld = was; } }
function Script() { this.nonce = ''; this._text = null; this._src = null; this.onload = null; this.onerror = null; }
Object.defineProperty(Script.prototype, 'textContent', { set: function(v) {
    if (__kit.tt && !(v && v.trusted === 'script')) throw new TypeError('requires TrustedScript');
    this._text = __kit.tt ? v.text : String(v); } });
Object.defineProperty(Script.prototype, 'src', { set: function(v) {
    if (__kit.tt && !(v && v.trusted === 'url')) throw new TypeError('requires TrustedScriptURL');
    this._src = __kit.tt ? v.text : String(v); } });
Script.prototype.remove = function() {};
function Blob(parts) { this._text = parts.join(''); }
var URL = { createObjectURL: function(b) { var u = 'blob:page/' + (++__blobSeq); __blobs[u] = b._text; return u; },
            revokeObjectURL: function(u) { delete __blobs[u]; } };
function CustomEvent(type) { this.type = type; }
function Event(type) { this.type = type; }
var __head = { appendChild: function(s) {
    __kit.appended++;
    if (s._src !== null) {
        __kit.blobAttempts++;
        if (__kit.blob && __blobs[s._src] !== undefined) __kit.pending.push(s); else if (s.onerror) s.onerror();
        return;
    }
    if (!__kit.inline || s._text === null || (__kit.nonce && s.nonce !== __kit.nonce)) return;
    __kit.inlineRan++;
    __runMain(s._text);
} };
function __flushBlobs() {
    var p = __kit.pending; __kit.pending = [];
    p.forEach(function(s) { __kit.blobsRan++; __runMain(__blobs[s._src]); if (s.onload) s.onload(); });
}
function __attrsLeft() { return Object.keys(__attrs).length; }
function __pageWorldKit(doc) {
    doc.documentElement = { setAttribute: function(k, v) { __attrs[k] = String(v); },
                            getAttribute: function(k) { return Object.prototype.hasOwnProperty.call(__attrs, k) ? __attrs[k] : null; },
                            removeAttribute: function(k) { delete __attrs[k]; } };
    doc.head = __head;
    doc.createElement = function() { return new Script(); };
    var qs = doc.querySelector;
    doc.querySelector = function(q) { return q === 'script[nonce]' ? (__kit.nonce ? { nonce: __kit.nonce } : null) : qs.call(doc, q); };
    doc.addEventListener = function(type, fn) { __kit.listeners.push({ type: type, fn: fn, main: mainWorld }); };
    doc.dispatchEvent = function(e) {
        __kit.listeners.forEach(function(l) {
            if (l.type !== e.type) return;
            var was = mainWorld; mainWorld = l.main; try { l.fn(e); } finally { mainWorld = was; }
        });
        return true;
    };
}
var window = { trustedTypes: { createPolicy: function(name, rules) {
    return { createScript: function(x) { return { trusted: 'script', text: rules.createScript(x) }; },
             createScriptURL: function(x) { return { trusted: 'url', text: rules.createScriptURL(x) }; } };
} } };
function __worldProp(obj, name, value) {
    Object.defineProperty(obj, name, { configurable: true, get: function() { return inMain() ? value : undefined; } });
}
function __worldKeys(hidden) {
    return new Proxy({}, {
        ownKeys: function(t) { return inMain() ? Object.keys(hidden) : []; },
        getOwnPropertyDescriptor: function(t, k) {
            return (inMain() && Object.prototype.hasOwnProperty.call(hidden, k)) ? { value: hidden[k], enumerable: true, configurable: true, writable: true } : undefined;
        },
        get: function(t, k) { return (inMain() && Object.prototype.hasOwnProperty.call(hidden, k)) ? hidden[k] : undefined; }
    });
}
"""#

/// 起一个装好两种环境的上下文:先放 `pageWorldKit`,再放这一页自己的 DOM(`page`,要定义 `document`),再跑 `setup`。
private func pageWorldContext(page: String, setup: String) -> JSContext? {
    guard let ctx = JSContext() else { return nil }
    ctx.exceptionHandler = { _, err in print("    JS 异常: \(err?.toString() ?? "?")") }
    ctx.evaluateScript(pageWorldKit)
    ctx.evaluateScript(page)
    ctx.evaluateScript("__pageWorldKit(document);")
    ctx.evaluateScript(setup)
    return ctx
}

private func int(_ ctx: JSContext, _ expr: String) -> Int32 { ctx.evaluateScript(expr)?.toInt32() ?? -1 }
private func str(_ ctx: JSContext, _ js: String) -> String { ctx.evaluateScript(js)?.toString() ?? "" }

// ---- Spotify 网页版:页面 CSP 不放内联脚本、也没有 nonce,走 inPageWorld 的应答器 ----

private let spotifyPage = #"""
function __track(id, name, artist, album, ms) {
    return { uri: 'spotify:track:' + id, name: name, artists: [{ name: artist }], album: { name: album }, duration: { milliseconds: ms } };
}
var __cur = __track('4uLU6hMCjMI75M1A2tKUQC', 'Song A', 'Artist A', 'Album A', 215000);
var __next = __track('7ouMYWpwJ422jRcDASZB7P', 'Song B', 'Artist B', 'Album B', 180000);
var __spState = { pos: 45300, age: 200, speed: 1, paused: false };
var __api = {
    getState: function() { return { isPaused: __spState.paused, isBuffering: false, positionAsOfTimestamp: __spState.pos,
                                     timestamp: Date.now() - __spState.age, duration: 215000, speed: __spState.speed, item: __cur }; },
    getQueue: function() { return { current: __cur, queued: [], nextUp: [__next] }; }
};
var __fiber = { memoizedProps: { children: null }, return: { memoizedProps: { playerAPI: __api }, return: null } };
var __widget = __worldKeys({ '__reactFiber$stub': __fiber });
var __widgetTestID = 'now-playing-widget';
function __matches(q, sel) { return String(q).split(',').some(function(p) { return p.trim() === sel; }); }
var document = {
    title: 'Song A ' + String.fromCharCode(8226) + ' Artist A',
    querySelector: function(q) {
        if (q === '[data-testid=playback-position]') return { textContent: '0:45' };
        if (q === '[data-testid=playback-duration]') return { textContent: '3:35' };
        if (__matches(q, '[data-testid=' + __widgetTestID + ']')) return __widget;
        return null;
    }
};
"""#

/// Spotify 的页面安全策略(实测 open.spotify.com):`script-src` 里没有 `'unsafe-inline'`、没有 nonce,放 `blob:`;没有 Trusted Types。
private let spotifyCSP = "__kit.inline = false; __kit.nonce = null; __kit.tt = false; delete window.trustedTypes;"

private func spotifyQueueAcrossWorlds() {
    typealias S = PlayerQueryServer
    let want = [["Song A", "Artist A", "Album A", "215000", "spotify:track:4uLU6hMCjMI75M1A2tKUQC"],
                ["Song B", "Artist B", "Album B", "180000", "spotify:track:7ouMYWpwJ422jRcDASZB7P"]]
        .map { $0.joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
    expectEqual(S.spotifyWebQueueJS.contains("\"") || S.spotifyWebQueueJS.contains("\\"), false,
                "Spotify 网页版队列 JS: 包过之后仍没有双引号和反斜杠")

    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP + "safari = true;") {
        expectEqual(str(ctx, S.spotifyWebQueueJS), want, "Spotify 网页版队列 JS 主环境(Safari): 直接读组件树")
        expectEqual(int(ctx, "__kit.appended"), 0, "Spotify 网页版队列 JS 主环境(Safari): 不往页面里插脚本")
    }
    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP) {
        expectEqual(str(ctx, S.spotifyWebQueueJS), "NOTFOUND", "Spotify 网页版队列 JS 隔离环境: 头一次内联脚本被 CSP 挡,读不到")
        expectEqual(int(ctx, "__kit.blobAttempts"), 1, "Spotify 网页版队列 JS 隔离环境: 头一次装一个 blob 应答器")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "Spotify 网页版队列 JS 隔离环境: 头一次也不留属性")
        ctx.evaluateScript("__flushBlobs();")
        let before = int(ctx, "__kit.appended")
        expectEqual(str(ctx, S.spotifyWebQueueJS), want, "Spotify 网页版队列 JS 隔离环境: 应答器装好之后经事件读回同一份队列")
        expectEqual(str(ctx, S.spotifyWebQueueJS), want, "Spotify 网页版队列 JS 隔离环境: 再读一次照样读到")
        expectEqual(int(ctx, "__kit.appended") - before, 0, "Spotify 网页版队列 JS 隔离环境: 应答器答上了就不再插脚本")
        expectEqual(int(ctx, "__kit.blobsRan"), 1, "Spotify 网页版队列 JS 隔离环境: 应答器只装一次")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "Spotify 网页版队列 JS 隔离环境: 结果和请求两个属性读完都删掉")
    }
    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP + "__kit.blob = false;") {
        expectEqual(str(ctx, S.spotifyWebQueueJS), "NOTFOUND", "Spotify 网页版队列 JS: blob 也被挡时读不到")
        expectEqual(str(ctx, S.spotifyWebQueueJS), "NOTFOUND", "Spotify 网页版队列 JS: blob 被挡,再读一次还是读不到")
        expectEqual(int(ctx, "__kit.blobAttempts"), 1, "Spotify 网页版队列 JS: 装不上的应答器每一页只试一次")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "Spotify 网页版队列 JS: 读不到也不留属性")
    }
}

private func spotifyProbeAcrossWorlds() {
    typealias P = BrowserPositionProbe
    guard let js = P.filledSiteScript(platformID: "spotifyWeb", expectedDuration: 215.4) else {
        expectEqual(true, false, "Spotify 网页版探针: 站点规则里没有 spotifyWeb")
        return
    }
    func read(_ ctx: JSContext) -> P.Reading? { P.parseReading(fromOsascriptOutput: str(ctx, js)) }
    func preciseNear(_ r: P.Reading?, _ secs: Double) -> Bool { r?.precise.map { abs($0.seconds - secs) < 0.1 } ?? false }

    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP + "safari = true;") {
        let r = read(ctx)
        expectEqual(preciseNear(r, 45.5) && r?.spotifyTrackID == "4uLU6hMCjMI75M1A2tKUQC", true,
                    "Spotify 网页版探针主环境(Safari): 精确读数和曲目 ID 直接读")
        expectEqual(int(ctx, "__kit.appended"), 0, "Spotify 网页版探针主环境(Safari): 不往页面里插脚本")
    }
    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP) {
        let first = read(ctx)
        expectEqual(first?.seconds == 45 && first?.precise == nil && first?.spotifyTrackID == nil, true,
                    "Spotify 网页版探针隔离环境: 应答器还没装好的那一次退回整秒读数")
        ctx.evaluateScript("__flushBlobs();")
        let second = read(ctx)
        expectEqual(preciseNear(second, 45.5), true, "Spotify 网页版探针隔离环境: 应答器装好后读到精确读数")
        expectEqual(second?.spotifyTrackID, "4uLU6hMCjMI75M1A2tKUQC", "Spotify 网页版探针隔离环境: 曲目 ID 一起读到")
        ctx.evaluateScript("__spState.paused = true;")
        expectEqual(read(ctx)?.precise, nil, "Spotify 网页版探针隔离环境: 播放器状态说暂停照样不外推(字段原样搬过来)")
        ctx.evaluateScript("__spState.paused = false; __spState.speed = 0;")
        expectEqual(read(ctx)?.precise, nil, "Spotify 网页版探针隔离环境: speed 为 0 照样不外推")
        expectEqual(int(ctx, "__kit.blobsRan"), 1, "Spotify 网页版探针隔离环境: 应答器只装一次(状态函数不带参数,编号不变)")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "Spotify 网页版探针隔离环境: 不留属性")
    }
    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP + "__kit.blob = false;") {
        ctx.evaluateScript("__flushBlobs();")
        let r = read(ctx)
        expectEqual(r?.seconds == 45 && r?.precise == nil, true, "Spotify 网页版探针: 进不了主环境时照旧交整秒读数")
    }
}

/// Spotify 改版后正在播放那块叫 `now-playing-widget-v2`(组件树、封面一样):进度探针、队列、广告判据两种环境都要找得到它。
private func spotifyWidgetV2AcrossWorlds() {
    guard let probe = BrowserPositionProbe.filledSiteScript(platformID: "spotifyWeb", expectedDuration: 215.4) else {
        expectEqual(true, false, "Spotify 新版正在播放块: 站点规则里没有 spotifyWeb")
        return
    }
    let v2 = "__widgetTestID = 'now-playing-widget-v2';"
    let want = "Song A\u{1f}Artist A\u{1f}Album A\u{1f}215000\u{1f}spotify:track:4uLU6hMCjMI75M1A2tKUQC"
    func read(_ ctx: JSContext) -> BrowserPositionProbe.Reading? { BrowserPositionProbe.parseReading(fromOsascriptOutput: str(ctx, probe)) }
    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP + "safari = true;" + v2) {
        let r = read(ctx)
        expectEqual(r?.precise.map { abs($0.seconds - 45.5) < 0.1 } == true && r?.spotifyTrackID == "4uLU6hMCjMI75M1A2tKUQC", true,
                    "Spotify 新版正在播放块主环境(Safari): 精确读数和曲目 ID")
        expectEqual(str(ctx, PlayerQueryServer.spotifyWebQueueJS).hasPrefix(want), true, "Spotify 新版正在播放块主环境(Safari): 队列")
        expectEqual(str(ctx, SpotifyWebAdProbe.probeJS), "0|0|0|0", "Spotify 新版正在播放块: 广告判据找得到这一块")
    }
    if let ctx = pageWorldContext(page: spotifyPage, setup: spotifyCSP + v2) {
        _ = str(ctx, PlayerQueryServer.spotifyWebQueueJS)
        _ = read(ctx)
        ctx.evaluateScript("__flushBlobs();")
        expectEqual(read(ctx)?.spotifyTrackID, "4uLU6hMCjMI75M1A2tKUQC", "Spotify 新版正在播放块隔离环境: 应答器装好后读到曲目 ID")
        expectEqual(str(ctx, PlayerQueryServer.spotifyWebQueueJS).hasPrefix(want), true, "Spotify 新版正在播放块隔离环境: 队列")
    }
}

// ---- YouTube Music:页面 CSP 要 nonce 和 Trusted Types,内联脚本过得去 ----

private let youTubeMusicProbePage = #"""
var __video = { paused: false, currentTime: 57.4 };
var __player = { className: 'html5-video-player' };
__worldProp(__player, 'getPlayerResponse', function() { return { videoDetails: { videoId: 'e-ORhEE9VVg', musicVideoType: 'MUSIC_VIDEO_TYPE_OMV' } }; });
var navigator = { mediaSession: { metadata: { title: 'Song', artwork: [{ src: 'https://lh3.googleusercontent.com/a=w60' }, { src: 'https://lh3.googleusercontent.com/a=w544' }] } } };
var document = {
    title: 'Song | YouTube Music',
    querySelector: function(q) {
        if (q === '.time-info') return { textContent: ' 0:57 / 4:04 ' };
        if (q === 'video') return __video;
        if (q === '#movie_player') return __player;
        return null;
    }
};
"""#

private func youTubeMusicProbeIdentityAcrossWorlds() {
    typealias P = BrowserPositionProbe
    guard let js = P.filledSiteScript(platformID: "youtubeMusic", expectedDuration: 244) else {
        expectEqual(true, false, "YouTube Music 探针: 站点规则里没有 youtubeMusic")
        return
    }
    expectEqual(js.contains("\"") || js.contains("\\"), false, "YouTube Music 探针: 包过之后仍没有双引号和反斜杠")
    let ident = P.VideoIdentity(videoID: "e-ORhEE9VVg", musicVideoType: "MUSIC_VIDEO_TYPE_OMV")
    if let ctx = pageWorldContext(page: youTubeMusicProbePage, setup: "safari = true;") {
        let r = P.parseReading(fromOsascriptOutput: str(ctx, js))
        expectEqual(r?.seconds == 57 && r?.video == ident, true, "YouTube Music 探针主环境(Safari): 视频身份直接读")
        expectEqual(int(ctx, "__kit.appended"), 0, "YouTube Music 探针主环境(Safari): 不往页面里插脚本")
    }
    if let ctx = pageWorldContext(page: youTubeMusicProbePage, setup: "") {
        let r = P.parseReading(fromOsascriptOutput: str(ctx, js))
        expectEqual(r?.seconds == 57 && r?.video == ident, true, "YouTube Music 探针隔离环境: 视频身份经内联脚本读回")
        expectEqual(r?.precise != nil, true, "YouTube Music 探针隔离环境: 精确读数照旧在当前环境读")
        expectEqual(int(ctx, "__kit.inlineRan"), 1, "YouTube Music 探针隔离环境: 插一次内联脚本")
        expectEqual(int(ctx, "__kit.blobAttempts"), 0, "YouTube Music 探针隔离环境: 内联过得去就不装应答器")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "YouTube Music 探针隔离环境: 不留属性")
    }
    if let ctx = pageWorldContext(page: youTubeMusicProbePage, setup: "__kit.inline = false; __kit.blob = false;") {
        let raw = str(ctx, js)
        let r = P.parseReading(fromOsascriptOutput: raw)
        expectEqual(r?.seconds == 57 && r?.video == nil && r?.precise != nil, true,
                    "YouTube Music 探针: 进不了主环境时只少视频身份,其余照旧")
        expectEqual(raw.contains("NOTFOUND"), false, "YouTube Music 探针: 视频身份读不到写空,不把 NOTFOUND 带进读数")
    }
}

private let youTubeMusicControlsPage = #"""
Object.defineProperty(this, 'ytcfg', { configurable: true, get: function() { return inMain() ? { d: function() {} } : undefined; } });
var __vol = { page: 40, applied: 40 };
var __slider = { dispatchEvent: function(e) { if (e.type === 'change') __vol.applied = __vol.page; } };
Object.defineProperty(__slider, 'value', {
    get: function() { return inMain() ? __vol.page : this._iso; },
    set: function(v) { if (inMain()) __vol.page = Number(v); else this._iso = v; }
});
var __bars = { shuffle: false, queueCalls: 0, clicks: 0 };
var __bar = {
    getAttribute: function(n) {
        if (n === 'repeat-mode') return 'ALL';
        if (n === 'shuffle-on') return __bars.shuffle ? '' : null;
        return null;
    },
    querySelector: function(q) {
        if (q === 'ytmusic-like-button-renderer') return { getAttribute: function(n) { return n === 'like-status' ? 'LIKE' : null; } };
        if (q === 'yt-icon-button.repeat') return { click: function() {} };
        if (q === 'yt-icon-button.shuffle') return { click: function() { __bars.clicks++; __bars.shuffle = !__bars.shuffle; } };
        return null;
    }
};
__worldProp(__bar, 'queue', { shuffle: function() { __bars.queueCalls++; __bars.shuffle = !__bars.shuffle; } });
var __video = { paused: false };
var navigator = { mediaSession: { metadata: { title: 'Song' } } };
var document = {
    title: '',
    querySelector: function(q) {
        if (q === 'ytmusic-player-bar') return __bar;
        if (q === 'video') return __video;
        if (q === '#volume-slider') return __slider;
        return null;
    }
};
"""#

private func youTubeMusicControlsAcrossWorlds() {
    typealias Y = YouTubeMusicWebControls
    let blocked = "__kit.inline = false; __kit.blob = false;"
    for js in [Y.readJS(title: "Song"), Y.setVolumeJS(30, title: "Song", force: true), Y.setModeJS(.shuffle, title: "Song", force: true)] {
        expectEqual(js.contains("\"") || js.contains("\\"), false, "网页版控制: 包过之后仍没有双引号和反斜杠")
    }

    // 读:音量条的 value
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: "safari = true;") {
        expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:ALL|LIKE|40|0", "网页版读回主环境(Safari): 音量直接读")
        expectEqual(int(ctx, "__kit.appended"), 0, "网页版读回主环境(Safari): 不往页面里插脚本")
    }
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: "") {
        expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:ALL|LIKE|40|0", "网页版读回隔离环境: 音量经内联脚本读回")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "网页版读回隔离环境: 不留属性")
    }
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: blocked) {
        expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:ALL|LIKE||0", "网页版读回: 进不了主环境时只少音量,其余照旧")
    }
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: "__slider._iso = 77;") {
        expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:ALL|LIKE|40|0",
                    "网页版读回隔离环境: 旧版在隔离环境里留下的 value 不算看得见,照样读页面那份")
    }

    // 写:音量
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: "safari = true;") {
        expectEqual(str(ctx, Y.setVolumeJS(30, title: "Song", force: true)), "SET:30", "网页版音量主环境(Safari): 直接写")
        expectEqual(int(ctx, "__vol.applied") == 30 && int(ctx, "__kit.appended") == 0, true,
                    "网页版音量主环境(Safari): 页面收到 change 时值已经是 30,不插脚本")
    }
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: "") {
        expectEqual(str(ctx, Y.setVolumeJS(30, title: "Song", force: true)), "SET:30", "网页版音量隔离环境: 经内联脚本写")
        expectEqual(int(ctx, "__vol.page") == 30 && int(ctx, "__vol.applied") == 30, true,
                    "网页版音量隔离环境: 页面自己的 value 变了、change 事件按新值生效")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "网页版音量隔离环境: 不留属性")
    }
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: blocked) {
        expectEqual(str(ctx, Y.setVolumeJS(30, title: "Song", force: true)), "NOTFOUND",
                    "网页版音量: 进不了主环境时回 NOTFOUND,不在隔离环境里假装写成")
        expectEqual(int(ctx, "__vol.page"), 40, "网页版音量: 进不了主环境时页面音量不动")
    }

    // 写:切随机用 queue.shuffle()
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: "safari = true;") {
        expectEqual(str(ctx, Y.setModeJS(.shuffle, title: "Song", force: true)), "SET:ALL", "网页版随机主环境(Safari): 切到随机")
        expectEqual(int(ctx, "__bars.queueCalls") == 1 && int(ctx, "__bars.clicks") == 0 && int(ctx, "__kit.appended") == 0, true,
                    "网页版随机主环境(Safari): 直接调 queue.shuffle(),不点键、不插脚本")
    }
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: "") {
        expectEqual(str(ctx, Y.setModeJS(.shuffle, title: "Song", force: true)), "SET:ALL", "网页版随机隔离环境: 切到随机")
        expectEqual(int(ctx, "__bars.queueCalls") == 1 && int(ctx, "__bars.clicks") == 0, true,
                    "网页版随机隔离环境: 经内联脚本调 queue.shuffle(),不点键")
        expectEqual(int(ctx, "__bars.shuffle"), 1, "网页版随机隔离环境: 随机开了")
    }
    if let ctx = pageWorldContext(page: youTubeMusicControlsPage, setup: blocked) {
        expectEqual(str(ctx, Y.setModeJS(.shuffle, title: "Song", force: true)), "SET:ALL", "网页版随机: 进不了主环境时切随机")
        expectEqual(int(ctx, "__bars.queueCalls") == 0 && int(ctx, "__bars.clicks") == 1, true,
                    "网页版随机: 进不了主环境时退回点随机键")
    }
}

// ---- YouTube Music 新版播放条:没有 ytmusic-player-bar、.time-info、#volume-slider,底栏是 ytmusic-miniplayer(02 章决策 287) ----
//
// 假页面照实测的样子:循环档和随机开关在页面状态 `ytmusic-app.getState().queue` 里(页面属性,只有主环境看得见),点键之后
// 页面状态当场变、键上的 `aria-pressed` 要等 `__render()`(页面重画)才跟上;没重画之前再点一下,页面按旧状态处理(跟没点一样)。
// 音量条是原生 `<input>`,两种环境都读写得到。队列元素的 `data`、播放器的 `getVideoData` / `getPlayerResponse` 只有主环境看得见。

private let youTubeMusicMiniplayerPage = #"""
Object.defineProperty(this, 'ytcfg', { configurable: true, get: function() { return inMain() ? { d: function() {} } : undefined; } });
var __order = ['NONE', 'ALL', 'ONE'];
var __st = { repeat: 'ALL', shuffle: false, like: 'true', hasLike: true, likeAria: true, ad: false, bar: false, stateReads: 0,
             shown: { repeat: 'ALL', shuffle: false, like: 'true' }, clicks: { repeat: 0, shuffle: 0, like: 0 }, events: [] };
function __render() { __st.shown.repeat = __st.repeat; __st.shown.shuffle = __st.shuffle; __st.shown.like = __st.like; }
function __btn(get, click) { return { getAttribute: function(n) { return n === 'aria-pressed' ? get() : null; }, click: click }; }
var __repeatBtn = __btn(function() { return __st.shown.repeat === 'NONE' ? 'false' : 'true'; },
                        function() { __st.clicks.repeat++; __st.repeat = __order[(__order.indexOf(__st.shown.repeat) + 1) % 3]; });
var __shuffleBtn = __btn(function() { return __st.shown.shuffle ? 'true' : 'false'; },
                         function() { __st.clicks.shuffle++; __st.shuffle = !__st.shown.shuffle; });
var __likeBtn = __btn(function() { return __st.likeAria ? __st.shown.like : null; },
                      function() { __st.clicks.like++; __st.like = __st.shown.like === 'true' ? 'false' : 'true'; });
var __slider = { value: '40', dispatchEvent: function(e) { __st.events.push(e.type + ':' + this.value); } };
var __mini = { querySelector: function(q) {
    if (q === '.ytmusicPlayerControlsRepeatButton button') return __repeatBtn;
    if (q === '.ytmusicPlayerControlsShuffleButton button') return __shuffleBtn;
    if (q === 'like-button-view-model button') return __st.hasLike ? __likeBtn : null;
    if (q === 'slider-shape input#slider') return __slider;
    return null;
} };
var __classicBar = {
    getAttribute: function(n) { return n === 'repeat-mode' ? 'NONE' : null; },
    querySelector: function(q) {
        if (q === 'ytmusic-like-button-renderer') return { getAttribute: function(n) { return n === 'like-status' ? 'INDIFFERENT' : null; } };
        return null;
    }
};
var __classicSlider = { value: 77 };
var __app = {};
__worldProp(__app, 'getState', function() { __st.stateReads++; return { queue: { repeatMode: __st.repeat, shuffleEnabled: __st.shuffle } }; });
var __video = { paused: false, currentTime: 57.4 };
var __player = { querySelector: function(q) { return q === 'video' ? __video : null; } };
Object.defineProperty(__player, 'className', { get: function() { return 'html5-video-player' + (__st.ad ? ' ad-showing' : ''); } });
__worldProp(__player, 'getVideoData', function() { return { video_id: 'raBobo3GZYA' }; });
__worldProp(__player, 'getPlayerResponse', function() { return { videoDetails: { videoId: 'raBobo3GZYA', musicVideoType: 'MUSIC_VIDEO_TYPE_ATV' } }; });
function __run(text, id) { return { text: text, navigationEndpoint: { browseEndpoint: { browseId: id } } }; }
function __item(data, selected) {
    var el = { hasAttribute: function(n) { return n === 'selected' && selected; } };
    __worldProp(el, 'data', data);
    return el;
}
var __items = [
    __item({ videoId: 'raBobo3GZYA', longBylineText: { runs: [__run('Rick Astley', 'UCrick'), { text: ' • ' }, __run('Earlier Copy', 'MPREb_copy')] } }, false),
    __item({ videoId: 'counterpart', selected: true, longBylineText: { runs: [__run('Artist', 'UCartist'), { text: ' • ' }, __run('Other Album', 'MPREb_other')] } }, true),
    __item({ videoId: 'raBobo3GZYA', selected: true, longBylineText: { runs: [__run('Rick Astley', 'UCrick'), { text: ' • ' },
            __run('Whenever You Need Somebody', 'MPREb_dcYZhAh5urI'), { text: ' • ' }, { text: '1987' }] } }, true)
];
var navigator = { mediaSession: { metadata: { title: 'Song', artwork: [{ src: 'https://lh3.googleusercontent.com/a=w544' }] } } };
var document = {
    title: 'Song | YouTube Music',
    querySelector: function(q) {
        if (q === 'ytmusic-player-bar') return __st.bar ? __classicBar : null;
        if (q === '.time-info') return __st.bar ? { textContent: '1:00 / 4:04' } : null;
        if (q === '#volume-slider') return __st.bar ? __classicSlider : null;
        if (q === 'ytmusic-miniplayer' || q === '.time-info, ytmusic-miniplayer') return __mini;
        if (q === 'ytmusic-miniplayer .ytMusicMiniPlayerTimeInfo') return __st.ad ? null : { textContent: '0:57 / 4:04' };
        if (q === '#movie_player') return __player;
        if (q === 'video') return __video;
        if (q === 'ytmusic-app') return __app;
        if (q.indexOf('.ytp-ad-badge') >= 0 || q.indexOf('.ytp-ad-simple-ad-badge') >= 0) return __st.ad ? { textContent: 'Ad' } : null;
        return null;
    },
    querySelectorAll: function(q) { return q === 'ytmusic-player-queue-item' ? __items : []; }
};
"""#

private func youTubeMusicMiniplayerAcrossWorlds() {
    typealias Y = YouTubeMusicWebControls
    typealias P = BrowserPositionProbe
    typealias A = YouTubeMusicAdProbe
    let blocked = "__kit.inline = false; __kit.blob = false;"
    let worlds: [(String, String)] = [("主环境(Safari)", "safari = true;"), ("隔离环境", "")]
    for js in [Y.readJS(title: "Song"), Y.setModeJS(.repeatOne, title: "Song", force: true), Y.setLikeJS(liked: true, title: "Song", force: true),
               Y.setVolumeJS(30, title: "Song", force: true), A.probeJS(title: "Song", playing: true)] {
        expectEqual(js.contains("\"") || js.contains("\\"), false, "新版播放条: 注入的 JS 没有双引号和反斜杠")
    }
    guard let probe = P.filledSiteScript(platformID: "youtubeMusic", expectedDuration: 244) else {
        expectEqual(true, false, "新版播放条: 站点规则里没有 youtubeMusic")
        return
    }
    let ident = P.VideoIdentity(videoID: "raBobo3GZYA", musicVideoType: "MUSIC_VIDEO_TYPE_ATV")

    for (world, setup) in worlds {
        // 进度探针:整秒文字在 .ytMusicMiniPlayerTimeInfo
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup) {
            let r = P.parseReading(fromOsascriptOutput: str(ctx, probe))
            expectEqual(r?.seconds == 57 && r?.precise != nil && r?.video == ident, true,
                        "新版播放条进度探针\(world): 读到 0:57、精确读数和视频身份")
            expectEqual(int(ctx, "__kit.appended") == 0, world.hasPrefix("主环境"), "新版播放条进度探针\(world): 只有隔离环境往页面里插脚本")
            expectEqual(int(ctx, "__attrsLeft()"), 0, "新版播放条进度探针\(world): 不留属性")
        }
        // 广告探针:专辑名从队列里正在放的那一条读
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup) {
            let raw = str(ctx, A.probeJS(title: "Song", playing: true))
            expectEqual(raw, "0|0|0||Whenever You Need Somebody", "新版播放条广告探针\(world): 专辑名取队列里视频 ID 对得上的选中项")
            expectEqual(A.parse(raw)?.album, "Whenever You Need Somebody", "新版播放条广告探针\(world): 解析出专辑名")
            expectEqual(int(ctx, "__kit.appended") == 0, world.hasPrefix("主环境"), "新版播放条广告探针\(world): 只有隔离环境往页面里插脚本")
            ctx.evaluateScript("__st.ad = true;")
            let before = int(ctx, "__kit.appended")
            expectEqual(str(ctx, A.probeJS(title: "Song", playing: true)), "1|1|0||", "新版播放条广告探针\(world): 广告期间判广告、不读专辑")
            expectEqual(int(ctx, "__kit.appended") - before, 0, "新版播放条广告探针\(world): 广告期间不往页面里插脚本")
            expectEqual(int(ctx, "__attrsLeft()"), 0, "新版播放条广告探针\(world): 不留属性")
        }
        // 网页版读回
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup) {
            expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:ALL|LIKE|40|0", "新版播放条读回\(world): 循环、赞、音量、随机")
            expectEqual(int(ctx, "__kit.appended") == 0, world.hasPrefix("主环境"), "新版播放条读回\(world): 只有隔离环境往页面里插脚本")
            ctx.evaluateScript("__video.paused = true;")
            expectEqual(str(ctx, Y.readJS(title: "Song")), "PAUSED:STATE:ALL|LIKE|40|0", "新版播放条读回\(world): 暂停页带 PAUSED: 前缀")
            ctx.evaluateScript("__video.paused = false; __st.hasLike = false;")
            expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:ALL||40|0", "新版播放条读回\(world): 没有赞键(不登录)时赞这一样读不到")
            expectEqual(str(ctx, Y.readJS(title: "Other")), "NOTFOUND", "新版播放条读回\(world): 放的不是这一首回 NOTFOUND")
            expectEqual(int(ctx, "__attrsLeft()"), 0, "新版播放条读回\(world): 不留属性")
        }
        // 音量:原生 input,改值再发 input、change
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup) {
            expectEqual(str(ctx, Y.setVolumeJS(30, title: "Song", force: true)), "SET:30", "新版播放条音量\(world): 写入")
            expectEqual(str(ctx, "__st.events.join(',')"), "input:30,change:30", "新版播放条音量\(world): 先改值,再发 input、change")
            expectEqual(str(ctx, Y.setVolumeJS(130, title: "Song", force: true)), "SET:100", "新版播放条音量\(world): 超出 0~100 夹住")
        }
        // 循环:一次脚本只点一下,没到目标回 STEP
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup + "__st.repeat = 'NONE'; __render();") {
            let js = Y.setModeJS(.repeatOne, title: "Song", force: true)
            expectEqual(str(ctx, js), "STEP:ALL", "新版播放条循环\(world): 关 → 单曲要两下,先点一下回 STEP")
            expectEqual(str(ctx, js), "STEP:ALL", "新版播放条循环\(world): 页面没重画时再点一下不算数,仍回 STEP")
            ctx.evaluateScript("__render();")
            expectEqual(str(ctx, js), "SET:ONE", "新版播放条循环\(world): 重画后再发一次到单曲")
            expectEqual(int(ctx, "__st.clicks.shuffle"), 0, "新版播放条循环\(world): 随机开关已对,不点随机键")
            expectEqual(str(ctx, js), "SET:ONE", "新版播放条循环\(world): 已在目标就不点")
            expectEqual(int(ctx, "__st.clicks.repeat"), 3, "新版播放条循环\(world): 一共点了三下(含没算数的那一下)")
            expectEqual(int(ctx, "__attrsLeft()"), 0, "新版播放条循环\(world): 不留属性")
        }
        // 随机:随机开关跟目标不一样就点一下;单曲循环关掉,列表循环留着
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup + "__st.repeat = 'ONE'; __render();") {
            expectEqual(str(ctx, Y.setModeJS(.shuffle, title: "Song", force: true)), "SET:NONE", "新版播放条随机\(world): 开随机、关单曲循环")
            expectEqual(int(ctx, "__st.shuffle") == 1 && int(ctx, "__st.clicks.shuffle") == 1, true, "新版播放条随机\(world): 随机键点了一下")
            expectEqual(str(ctx, Y.setModeJS(.shuffle, title: "Song", force: true)), "SET:NONE", "新版播放条随机\(world): 页面状态已开,不再点")
            expectEqual(int(ctx, "__st.clicks.shuffle"), 1, "新版播放条随机\(world): 按页面状态判,不按还没重画的键")
        }
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup) {
            expectEqual(str(ctx, Y.setModeJS(.list, title: "Song", force: true)), "SET:ALL", "新版播放条列表\(world): 列表循环开着就留着")
            expectEqual(int(ctx, "__st.clicks.repeat") + int(ctx, "__st.clicks.shuffle"), 0, "新版播放条列表\(world): 什么都不点")
        }
        // 点赞
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup) {
            expectEqual(str(ctx, Y.setLikeJS(liked: true, title: "Song", force: true)), "SET:LIKE", "新版播放条点赞\(world): 已赞就不点")
            expectEqual(str(ctx, Y.setLikeJS(liked: false, title: "Song", force: true)), "SET:LIKE",
                        "新版播放条点赞\(world): 取消赞点一下,回的是重画前的状态")
            expectEqual(str(ctx, "__st.like") + "/" + str(ctx, "__st.clicks.like"), "false/1", "新版播放条点赞\(world): 赞键点了一下")
            ctx.evaluateScript("__st.likeAria = false;")
            expectEqual(str(ctx, Y.setLikeJS(liked: true, title: "Song", force: true)), "NOTFOUND", "新版播放条点赞\(world): 读不懂赞键状态回 NOTFOUND")
            ctx.evaluateScript("__st.likeAria = true; __st.hasLike = false;")
            expectEqual(str(ctx, Y.setLikeJS(liked: true, title: "Song", force: true)), "NOTFOUND", "新版播放条点赞\(world): 没有赞键回 NOTFOUND")
            expectEqual(int(ctx, "__st.clicks.like"), 1, "新版播放条点赞\(world): 读不到时不乱点")
        }
        // 暂停页第一轮不动
        if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: setup + "__video.paused = true;") {
            expectEqual(str(ctx, Y.setVolumeJS(30, title: "Song", force: false)), "PAUSED:SKIP", "新版播放条\(world): 暂停页第一轮不动")
            expectEqual(str(ctx, "__slider.value"), "40", "新版播放条\(world): 暂停页第一轮音量不变")
        }
    }

    // 进不了主环境:进度和音量照旧,循环 / 随机写不了,读回只认得出「关」,专辑名读不到
    if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: blocked) {
        let r = P.parseReading(fromOsascriptOutput: str(ctx, probe))
        expectEqual(r?.seconds == 57 && r?.precise != nil && r?.video == nil, true, "新版播放条进度探针: 进不了主环境时只少视频身份")
        expectEqual(str(ctx, A.probeJS(title: "Song", playing: true)), "0|0|0||", "新版播放条广告探针: 进不了主环境时专辑名为空")
        expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:|LIKE|40|0", "新版播放条读回: 进不了主环境、循环键按着时分不出全部 / 单曲")
        ctx.evaluateScript("__st.repeat = 'NONE'; __render();")
        expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:NONE|LIKE|40|0", "新版播放条读回: 进不了主环境时循环键没按着就是关")
        expectEqual(str(ctx, Y.setModeJS(.repeatAll, title: "Song", force: true)), "NOTFOUND", "新版播放条循环: 进不了主环境回 NOTFOUND")
        expectEqual(int(ctx, "__st.clicks.repeat") + int(ctx, "__st.clicks.shuffle"), 0, "新版播放条循环: 进不了主环境时什么都不点")
        expectEqual(str(ctx, Y.setVolumeJS(25, title: "Song", force: true)), "SET:25", "新版播放条音量: 不用进主环境")
        expectEqual(int(ctx, "__attrsLeft()"), 0, "新版播放条: 进不了主环境也不留属性")
    }

    // 经典播放条和新版的同时在:只走经典那套
    if let ctx = pageWorldContext(page: youTubeMusicMiniplayerPage, setup: "safari = true; __st.bar = true;") {
        expectEqual(str(ctx, Y.readJS(title: "Song")), "STATE:NONE|INDIFFERENT|77|0", "两版都在: 网页版读回只读经典播放条")
        expectEqual(P.parseReading(fromOsascriptOutput: str(ctx, probe))?.seconds, 60, "两版都在: 进度探针只读 .time-info")
        expectEqual(str(ctx, A.probeJS(title: "Song", playing: true)), "0|0|0||", "两版都在: 广告探针只认经典播放条的 byline")
        expectEqual(int(ctx, "__st.stateReads") + int(ctx, "__kit.appended"), 0, "两版都在: 不读新版的页面状态、不插脚本")
    }
}

/// `setMode` 的重发:回 STEP 就隔 `repeatStepGap` 再发,最多共发 `maxRepeatSteps` 次。
private func youTubeMusicMiniplayerStepLoop() {
    typealias Y = YouTubeMusicWebControls
    expectEqual(Y.parseSet("STEP:ALL"), .step("ALL"), "网页版: 新版播放条点了一下循环键、还没到目标回 STEP")
    func drive(_ outcomes: [Y.SetOutcome]) -> (Y.SetOutcome, Int, [TimeInterval]) {
        var calls = 0, sleeps: [TimeInterval] = []
        let last = Y.stepUntilSet(sleep: { sleeps.append($0) }) {
            defer { calls += 1 }
            return outcomes[min(calls, outcomes.count - 1)]
        }
        return (last, calls, sleeps)
    }
    let twice = drive([.step("ALL"), .set("ONE")])
    expectEqual(twice.0 == .set("ONE") && twice.1 == 2 && twice.2 == [Y.repeatStepGap], true, "网页版: STEP 之后隔一会儿再发,到了就停")
    let stuck = drive([.step("ALL")])
    expectEqual(stuck.0 == .step("ALL") && stuck.1 == Y.maxRepeatSteps, true, "网页版: 一直到不了目标,最多发 maxRepeatSteps 次")
    let classic = drive([.set("ALL")])
    expectEqual(classic.1 == 1 && classic.2.isEmpty, true, "网页版: 经典播放条一次就回 SET,不重发、不等")
    let failed = drive([.failed])
    expectEqual(failed.0 == .failed && failed.1 == 1, true, "网页版: 写失败不重发")
}

import Foundation
import LyrimuseCore

/// 读引擎落盘的 Last.fm 镜像状态文件(lyrimuse-lastfm-status.json)。
///
/// 只有一种内容:凭据级致命错误,分两类(`reason`):授权失效(session key 被撤销,error 4/9)和 key 被拒
/// (Last.fm 要求 key 的持有人订阅 Last.fm Pro,error 10/26、认不出的 403 等,见 `LastfmErrorClassifier`)。
/// 引擎写入熔断时写这个文件(见 lyrimuse-engine/lastfm.go 的 writeLastfmMirrorStatus),读取路径撞上 key 被拒也写;
/// 之后提交成功会把它删掉。App 侧读到它就把账号卡渲染成红标,文案按 `keyRejected` 分 —— 没有这条通道的话,scrobble 全停时界面照样一片绿
/// ("已连接"只看本地 session key 非空,信息页走只读 API 照常出数据),用户从任何
/// 地方都发现不了。
enum LastfmMirrorStatus {
    struct Info: Decodable, Equatable {
        let error: Int
        let message: String
        let at: Int64
        /// `key_rejected` / `session`;旧版引擎写的文件没有这个字段。
        var reason: String?
        /// 应答的 HTTP 状态;旧版引擎写的文件没有。
        var status: Int?

        /// key 被拒(要订阅 Last.fm Pro),不是授权失效。没有 `reason` 的旧文件按 error 码判。
        var keyRejected: Bool {
            LastfmErrorClassifier.statusFileKeyRejected(reason: reason, error: error, status: status, message: message)
        }
    }

    private static let url = LyrimusePaths.configFile("lyrimuse-lastfm-status.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: Info?

    /// 当前的致命错误;文件不存在/解析失败都是 nil。按 mtime 缓存,文件没变时只是一次 stat。
    /// 只由 `LastfmMirrorStatusWatcher` 在后台读;界面一律读观察器发布的 `info`,主线程上不碰这里。
    static var current: Info? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = FileIO.decodeJSON(Info.self, from: url)
        return cached
    }

    /// 重新连接成功/主动断开时清掉 —— 旧错误描述的是上一把钥匙,留着会让新连接顶着
    /// 一个不属于它的红标(引擎侧也会在下次成功提交时删,这里是即时反馈)。
    /// 不碰 mtime 缓存(那把锁可能正被后台那次读握着):文件没了,下一次读按 mtime 为空自己清掉。
    @MainActor
    static func clear() {
        FileIO.remove(url)
        // 红标即时消失,不等观察器的下一跳。
        LastfmMirrorStatusWatcher.shared.noteCleared()
    }
}

/// 让"授权已失效"红标能**自愈**的观察器。引擎恢复后(重启进程 + 首次提交成功)
/// 会把状态文件删掉,但"文件被删"不在 SwiftUI 的观察体系里 —— 徽标所在的行没有任何
/// 被观察对象变化就不重渲染,红标滞留(实测:Last.fm 误报 error 4 → 熔断
/// 落文件 → 引擎重启自愈删了文件,侧边栏红标继续挂着)。反方向同样成立:App
/// 开着设置页时引擎熔断落了文件,红标也该自己冒出来,不用重开窗口。
///
/// 每 5 秒重读一次(LastfmMirrorStatus.current 按 mtime 缓存,常态代价是一次 stat),
/// 值真变了才发布 —— 订阅的视图只在红标该出现/消失的那一刻各重算一次,其余时间
/// objectWillChange 完全安静。App 启动时由 `LastfmMirrorNotifier` 订阅,从那一刻起就在跳(熔断要弹系统通知)。
///
/// 读文件在后台,回到主线程才发布:主线程上 stat 碰上磁盘卡住就是几秒的卡顿(14 章决策 194)。第一次读完之前
/// `info` 是 nil、`loaded` 是 false;要区分「没读到」和「读过、没有错误」的(系统通知)看 `loaded`。
///
/// 界面读 `info`;系统通知读 `fileInfo`(状态文件本身)。两者只在本机验证用的 `debug/lastfm-status` 盖着时不同,
/// 盖上去的那一份只给界面看,不弹通知、不记「弹过」。
@MainActor
final class LastfmMirrorStatusWatcher: ObservableObject {
    static let shared = LastfmMirrorStatusWatcher()

    /// 界面显示的结论:有调试覆盖时是覆盖值,否则同 `fileInfo`。
    @Published private(set) var info: LastfmMirrorStatus.Info?
    /// 状态文件里读到的结论。
    @Published private(set) var fileInfo: LastfmMirrorStatus.Info?
    /// `debug/lastfm-status` 盖上去的那一份;nil = 没盖。不落盘,App 重启即撤。
    private(set) var debugOverride: LastfmMirrorStatus.Info?
    /// 第一次后台读已经落下。
    @Published private(set) var loaded = false

    private var timer: Timer?
    /// 派出的那次后台读还没回来;没回来就不再派(磁盘卡住时不堆积)。
    private var readInFlight = false
    /// 每次后台读按派出顺序编号,只采用比已采用的更新的那次;`noteCleared` 把还在飞的那次作废。
    private var readsIssued = 0
    private var readsApplied = 0

    private init() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // 差几秒无所谓,让系统合并唤醒。
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// 在后台重读一次,读完发布;上一次还没读完就什么都不做。
    func refresh() {
        guard !readInFlight else { return }
        readInFlight = true
        readsIssued += 1
        let read = readsIssued
        Task.detached(priority: .utility) { [weak self] in
            let latest = LastfmMirrorStatus.current
            await self?.finishRead(latest, read: read)
        }
    }

    private func finishRead(_ latest: LastfmMirrorStatus.Info?, read: Int) {
        readInFlight = false
        guard read > readsApplied else { return }
        readsApplied = read
        if latest != fileInfo { fileInfo = latest }
        publishInfo()
        if !loaded { loaded = true }
    }

    private func publishInfo() {
        let shown = debugOverride ?? fileInfo
        if shown != info { info = shown }
    }

    /// 本机验证用(`debug/lastfm-status`):true = 当作 key 被拒,false = 当作授权失效,nil = 撤掉、交还状态文件。
    func setDebugOverride(keyRejected: Bool?) {
        debugOverride = keyRejected.map {
            $0 ? LastfmMirrorStatus.Info(error: 10, message: "Invalid API key - You must be granted a valid key by last.fm", at: 0,
                                         reason: "key_rejected", status: 403)
               : LastfmMirrorStatus.Info(error: 9, message: "Invalid session key - Please re-authenticate", at: 0,
                                         reason: "session", status: 200)
        }
        publishInfo()
    }

    /// `LastfmMirrorStatus.clear()` 删掉状态文件之后:当场发布「没有错误」,还在飞的那次读(可能读到删之前的文件)作废。
    func noteCleared() {
        readsApplied = readsIssued
        if fileInfo != nil { fileInfo = nil }
        publishInfo()
        if !loaded { loaded = true }
    }
}

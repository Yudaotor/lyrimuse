import Combine
import Foundation

/// 「已校准」名单:用户手动调过歌词时间轴的曲目,collector 不再自动给它们重选歌词源。
///
/// 为什么需要它:单曲校正值的 key 里含**歌词内容指纹**(见 LyricsOffsetStore.trackKey),
/// 后台一旦把这首歌的歌词换成另一份,指纹就变了,用户一句句听出来的那几百毫秒当场作废、
/// 界面上还毫无痕迹。2026-08-20 实测坐实这不是理论风险:那台机器 14 条校正记录里 13 条
/// 已经因为"内容换过"或"条目没了"而失联;而 qq 与 kugou 的分差常年只有 9 分(约 1330
/// 分里的 0.7%,时间戳行数完全相同),任何一次后台重搜都可能翻盘换源。
///
/// 语义上跟 collector 的 `manual_lyrics`(用户手改过歌词内容)并列:两者都是"用户已经
/// 亲手把这首歌弄对了,后台别再自作主张"。区别只在保护的东西不同 —— 那个保护内容本身,
/// 这个保护绑在内容上的那个校正值。
///
/// **key 用 EnrichCacheKeys.normalizedKey(归一化 artist|title|album)**,跟 enrich 缓存
/// 同一套,刻意**不是** LyricsOffsetStore 那个含内容指纹的 key:pin 要保护的是"这首歌",
/// 而内容指纹恰恰是会变的那一半,拿它当身份等于"内容一换 pin 也失效",正好把要防的事情
/// 放过去。
///
/// 落在 `~/.config/lyrimuse/lyrimuse-lyrics-pins.json` 这份独立小文件里,**不**塞进
/// enrich 缓存:collector 在内存里持有整份 enrich 缓存并会整份写回,往那个 JSON 里加字段
/// 会被下一次 saveEnrichCache 覆盖,想安全就得重启 collector(理由见 EnrichCacheStore
/// .delete 的长注释)—— 而校正值是在菜单栏里按一下就变一次的东西,每按一次重启一遍
/// collector 不可接受。collector 那边按 mtime 自己重读(见 collector/lyricspins.go),
/// 所以这里每次写完立刻生效,不需要 kickstart。
@MainActor
public final class LyricsPinStore: ObservableObject {
    public static let shared = LyricsPinStore()

    /// 落盘格式。`pins` 的值是记下这条 pin 的 unix 秒 —— 纯给人看(`cat` 一眼能看出哪首
    /// 是什么时候校准的),collector 只关心键在不在。刻意**不**在这里存校正毫秒数:那份值
    /// 的权威源是 UserDefaults(LyricsOffsetStore),复制一份到这里只会多一处会漂的状态。
    private struct File: Codable {
        var version: Int
        var pins: [String: Int]
    }

    private static let fileVersion = 1

    private static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-lyrics-pins.json")

    /// 实际落盘位置。生产环境永远是上面那个;selftest 会把它指到临时目录。
    private static var url = defaultURL

    /// **只给 selftest 用**:把落盘位置改到临时目录,并按新位置重新读一遍。
    ///
    /// 为什么必须有这个口子:这份文件的路径是绝对的、跟正在运行的 App 共用同一份,而
    /// selftest 要覆盖的断言里恰好包含 removeAll()(「清空全部时间轴校正」那条路径)——
    /// 不隔离的话,跑一次 selftest 就会把用户真实的已校准名单整份抹掉。生产代码里没有
    /// 任何调用点(改路径这件事本身也不该有第二个理由)。
    public static func redirectForTesting(to url: URL) {
        Self.url = url
        shared.pins = load()
    }

    /// 整份字典对外只读。发布出去是为了让「歌词管理」的工具栏计数和详情页徽章跟着变 ——
    /// 改动只来自用户动作(调偏移/重置/清空),频率低,不存在 LyricsOffsetStore 那边
    /// "20Hz 热路径重渲染"那类顾虑。
    @Published public private(set) var pins: [String: Int]

    private init() {
        pins = Self.load()
    }

    public var count: Int { pins.count }

    public func isPinned(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return pins[key] != nil
    }

    /// 钉住/解钉一首歌。幂等:状态没变就连盘都不写(菜单栏连点「提前」时,第一下之后
    /// 每一下都是"已经钉住了")。
    public func setPinned(_ pinned: Bool, forKey key: String, now: Date = Date()) {
        guard !key.isEmpty else { return }
        if pinned {
            guard pins[key] == nil else { return }
            pins[key] = Int(now.timeIntervalSince1970)
        } else {
            guard pins.removeValue(forKey: key) != nil else { return }
        }
        persist()
    }

    /// 删掉这些歌的 pin ——「歌词管理」里删除条目时连带调用:条目都没了,再钉着它没有
    /// 意义,而且留着会让"这首歌重新解析出来的新歌词"莫名其妙一上来就不许后台升级。
    public func remove(keys: Set<String>) {
        let before = pins.count
        for key in keys { pins.removeValue(forKey: key) }
        guard pins.count != before else { return }
        persist()
    }

    /// 清空整份名单。跟 LyricsOffsetStore.clearAllTrackOffsets 成对使用 —— 校正值都清了
    /// 就没有要保护的东西了。
    public func removeAll() {
        guard !pins.isEmpty else { return }
        pins.removeAll()
        persist()
    }

    private func persist() {
        let file = File(version: Self.fileVersion, pins: pins)
        guard let data = try? JSONEncoder().encode(file) else { return }
        // 目录理应早就存在(collector 的配置就在这儿),但"用户刚导入过配置/换过机器"这种
        // 情况下第一次写可能撞上目录不在,补一次 createDirectory 比丢掉这次写入划算。
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // .atomic:collector 会在任意时刻读这份文件,不能让它读到写一半的内容。
        try? data.write(to: Self.url, options: [.atomic])
    }

    private static func load() -> [String: Int] {
        guard
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            return [:]
        }
        return file.pins
    }
}

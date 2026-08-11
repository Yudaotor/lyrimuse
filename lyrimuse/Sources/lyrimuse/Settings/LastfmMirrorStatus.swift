import Foundation

/// 读 collector 落盘的 Last.fm 镜像状态文件(lyrimuse-lastfm-status.json)。
///
/// 只有一种内容:凭据级致命错误(session key 被撤销/API key 失效,error 4/9/10/26)。
/// collector 遇到它会熔断停止提交并写这个文件(见 collector/lastfm.go 的
/// writeLastfmMirrorStatus),之后第一次提交成功会把它删掉。App 侧读到它就把账号卡
/// 渲染成"授权已失效"红标 —— 没有这条通道的话,scrobble 全停时界面照样一片绿
/// ("已连接"只看本地 session key 非空,信息页走只读 API 照常出数据),用户从任何
/// 地方都发现不了(2026-08-11 审阅确认)。
enum LastfmMirrorStatus {
    struct Info: Decodable, Equatable {
        let error: Int
        let message: String
        let at: Int64
    }

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-lastfm-status.json")

    private static var cachedMTime: Date?
    private static var cached: Info?

    /// 当前的致命错误;文件不存在/解析失败都是 nil。按 mtime 缓存 —— 侧边栏徽标每次
    /// 渲染都会读这里,不能每次都做完整的读盘+解码。
    static var current: Info? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        return cached
    }

    /// 重新连接成功/主动断开时清掉 —— 旧错误描述的是上一把钥匙,留着会让新连接顶着
    /// 一个不属于它的红标(collector 侧也会在下次成功提交时删,这里是即时反馈)。
    static func clear() {
        try? FileManager.default.removeItem(at: url)
        cachedMTime = nil
        cached = nil
    }
}

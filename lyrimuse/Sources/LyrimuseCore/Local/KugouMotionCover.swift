import Foundation

/// 酷狗音乐本机缓存的专辑动态封面。引擎把它记成 `kgmv:<酷狗专辑 id>`(见引擎 `motioncoverkg.go`),并把酷狗容器里那份
/// (`KGDynamicArtwork/<专辑 id>.mp4`)拷进缓存目录的 `stageDirName`:App 不读别的 App 的容器(会弹「想访问其他 App 的数据」),
/// 只读拷过来的这份,不联网。3:4 竖幅,终审比中段帧、首帧的中间正方形。纯函数部分 selftest 钉着。见 03 章决策 69。
public enum KugouMotionCover {
    public static let scheme = "kgmv"
    /// 缓存目录里放拷过来的视频的子目录,引擎写同一处(`kugouMotionStageDirName`)。
    public static let stageDirName = "kugou-motion-covers"

    /// `kgmv:<专辑 id>` → 专辑 id;不是这种地址、id 形状不对为 nil。
    public static func albumID(from master: URL) -> String? {
        guard master.scheme == scheme else { return nil }
        let id = String(master.absoluteString.dropFirst(scheme.count + 1))
        return id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil ? id : nil
    }

    /// 引擎拷过来的那份视频。
    public static func stagedFile(albumID: String, cachesDir: URL = LyrimusePaths.cachesDir) -> URL {
        cachesDir.appendingPathComponent(stageDirName).appendingPathComponent("\(albumID).mp4")
    }
}

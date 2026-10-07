import Foundation

/// 「歌词管理」里一条的缩略图地址:封面(`cover_url`);没有封面时用播放这首时 App 交给引擎的视频帧(`video_frame_url`,
/// 见 03 章决策 39)。都没有为 nil。
public enum ManagerCoverURL {
    public static func from(_ entry: [String: Any]) -> URL? {
        for key in ["cover_url", "video_frame_url"] {
            if let s = entry[key] as? String, !s.isEmpty, let url = URL(string: s) { return url }
        }
        return nil
    }
}

import Foundation
import LyrimuseCore

// 「歌词管理」列宽的持久化。写法跟 AppSettings 一致(@Published + didSet 落 UserDefaults),
// 但没有并进 AppSettings:那边装的是全 App 生效的偏好(悬浮窗外观、菜单栏、语言…),而这三个
// 值只有「歌词管理」这一个窗口用得到,放在它自己的目录下更好找,也不会让 AppSettings 继续膨胀。
//
// 算术一律不在这里做,全部转调 LyricsColumnWidths 的纯函数(见那边注释)——这个类只负责
// "存/取 + 发布变更",这样夹值逻辑能在 lyrimuse-selftest 里被覆盖。
@MainActor
final class LyricsColumnWidthsStore: ObservableObject {
    static let shared = LyricsColumnWidthsStore()

    private enum Keys {
        // np: 前缀跟这个项目其它 UserDefaults key 保持一致(见 LyricsOffsetStore/AppSettings)。
        static let artist = "np:lyricsManagerColArtist"
        static let album = "np:lyricsManagerColAlbum"
        static let source = "np:lyricsManagerColSource"
    }

    private let defaults = UserDefaults.standard

    @Published var widths: LyricsColumnWidths {
        didSet {
            guard widths != oldValue else { return }
            defaults.set(Double(widths.artist), forKey: Keys.artist)
            defaults.set(Double(widths.album), forKey: Keys.album)
            defaults.set(Double(widths.source), forKey: Keys.source)
        }
    }

    private init() {
        // 任意一项没存过(object(forKey:) 为 nil)就整组用默认值——不逐项混搭,三列宽度是一组
        // 配套的值。存过的话再交给 sanitized 挡掉手改/老版本写进来的非法值。
        if defaults.object(forKey: Keys.artist) == nil
            || defaults.object(forKey: Keys.album) == nil
            || defaults.object(forKey: Keys.source) == nil {
            widths = LyricsColumnWidths.defaults
        } else {
            widths = LyricsColumnWidths.sanitized(LyricsColumnWidths(
                artist: CGFloat(defaults.double(forKey: Keys.artist)),
                album: CGFloat(defaults.double(forKey: Keys.album)),
                source: CGFloat(defaults.double(forKey: Keys.source))
            ))
        }
    }

    func reset() { widths = LyricsColumnWidths.defaults }
}

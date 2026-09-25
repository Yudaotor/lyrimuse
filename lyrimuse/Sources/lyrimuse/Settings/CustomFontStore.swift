import AppKit
import CoreText
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "custom-font")

/// 用户导入的自定义字体(.ttf / .otf):字体选择器除了系统已装字体,
/// 还能从本地文件导入。
///
/// 落盘 + 注册两件事分开:文件长期存在 `~/.config/lyrimuse/fonts/` 下(config 目录本来就是
/// 这个 App 所有持久数据的唯一落点,见 `LyrimuseIdentity` 头注),但 Core Text 的注册是
/// **进程级**的(`.process` scope)——不写进系统 Font Book,不用管理员权限,卸载 App 也不会
/// 在用户系统里留下孤儿字体;代价是每次启动都要重新注册一遍(`registerAll()`),这一步必须
/// 赶在 `AppSettings.shared` 第一次被访问**之前**——`AppSettings.init()` 末尾会用当前的
/// `fontFamilyName` 算一遍 `mainFont` 等派生字体(`recomputeFonts()`),这时如果自定义字体
/// 还没注册,`NSFontManager` 找不到那个族名,会静默落回系统字体,直到下一次设置变动才会
/// 纠正过来。调用点在 `AppDelegate.applicationDidFinishLaunching` 最前面。
///
/// 配置搬家只带族名、不带字体文件(中文字体动辄十几 MB);换机后指向的字体不在,选择器按 `isAvailable`
/// 在名字后面标「未安装」。
@MainActor
final class CustomFontStore: ObservableObject {
    static let shared = CustomFontStore()

    /// 一款已导入的字体族:同一族的几个文件(Regular / Bold …)只占一行,删除时一起删。
    struct ImportedFont: Identifiable, Equatable {
        let familyName: String
        let fileNames: [String]
        var id: String { familyName }
    }

    /// 注册成功的导入字体,按族名排序,给 `FontFamilyPicker` 展示用。注册失败的文件不列:选了也只会显示系统字体。
    @Published private(set) var fonts: [ImportedFont] = []
    /// 此刻进程里能用的字体族名(`CustomFontFile.availableFamilyNames`),在注册 / 反注册之后刷新。
    @Published private(set) var availableFamilies: Set<String> = []

    enum ImportError: Error {
        /// 扩展名不是 .ttf / .otf。
        case unsupportedFormat
        /// 选中的文件读不出来(权限、没下载到本机、文件已被移走等)。
        case unreadable
        /// 读出来了,但 Core Text 认不出这是一份有效的字体。
        case invalidFont
    }

    private let fm = FileManager.default
    private var directory: URL { LyrimusePaths.configFile("fonts") }
    /// 本进程注册成功的文件名。
    private var registered: Set<String> = []
    /// 导入时先复制成这个前缀的临时文件、校验通过才替换正式文件;中途退出留下的在启动时清掉。
    private static let stagingPrefix = ".importing-"

    private init() {
        registerAll()
    }

    /// 族名此刻有没有字体可用(系统已装或导入并注册成功)。空串是跟随系统字体,永远可用。
    func isAvailable(_ family: String) -> Bool {
        !CustomFontFile.isMissing(family, available: availableFamilies)
    }

    /// 这个族名是不是导入字体(选择器的系统字体列表据此排除,免得同一款出现两次)。
    func isImported(_ family: String) -> Bool {
        fonts.contains { $0.familyName == family }
    }

    // MARK: - 导入 / 删除(设置页调用)

    /// 把一个本地字体文件收进这个 App 自己的目录并注册。同名文件覆盖——重新导入同一款字体是常见操作
    /// (换一份修过的文件),不该在磁盘上攒出好几份同名文件。先复制到临时文件并校验,通过才替换:新文件
    /// 读不到或不是字体时,原来那份照常可用。
    func importFont(from url: URL) throws {
        guard CustomFontFile.isSupported(url) else { throw ImportError.unsupportedFormat }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(url.lastPathComponent)
        // 选的就是这个目录里的那一份:已经在位,只补注册。
        if url.resolvingSymlinksInPath().standardizedFileURL == dest.resolvingSymlinksInPath().standardizedFileURL {
            guard registered.contains(dest.lastPathComponent) || register(dest) != nil else {
                throw ImportError.invalidFont
            }
            refresh()
            return
        }
        let staging = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString + ".tmp")
        do {
            try fm.copyItem(at: url, to: staging)
        } catch {
            logger.error("importFont: copy failed — \(String(describing: error), privacy: .public)")
            throw ImportError.unreadable
        }
        guard CustomFontFile.familyName(ofFontAt: staging) != nil else {
            try? fm.removeItem(at: staging)
            throw ImportError.invalidFont
        }
        if fm.fileExists(atPath: dest.path) {
            unregister(dest)
            do {
                _ = try fm.replaceItemAt(dest, withItemAt: staging)
            } catch {
                try? fm.removeItem(at: staging)
                register(dest)
                refresh()
                logger.error("importFont: replace failed — \(String(describing: error), privacy: .public)")
                throw ImportError.unreadable
            }
        } else {
            do {
                try fm.moveItem(at: staging, to: dest)
            } catch {
                try? fm.removeItem(at: staging)
                logger.error("importFont: move failed — \(String(describing: error), privacy: .public)")
                throw ImportError.unreadable
            }
        }
        guard register(dest) != nil else {
            try? fm.removeItem(at: dest)
            refresh()
            throw ImportError.invalidFont
        }
        refresh()
    }

    /// 反注册并删除这一族的全部文件,再把仍指向这一族的字体设置(悬浮歌词、灵动岛、菜单栏、歌词窗口完整 /
    /// 迷你五处)退回系统字体 —— 不退的话别处的按钮上留着一款查无此字的族名。系统里另装了同名字体族时不退,
    /// 那一族还在。先反注册再删文件:反过来万一删除中途失败,会留下「文件没了但 Core Text 仍然认得」的悬空注册。
    func remove(_ font: ImportedFont) {
        for name in font.fileNames {
            let url = directory.appendingPathComponent(name)
            unregister(url)
            try? fm.removeItem(at: url)
        }
        refresh()
        guard !isAvailable(font.familyName) else { return }
        let settings = AppSettings.shared
        if settings.fontFamilyName == font.familyName { settings.fontFamilyName = "" }
        if settings.notchFontFamilyName == font.familyName { settings.notchFontFamilyName = "" }
        if settings.menuBarLyricsFontFamily == font.familyName { settings.menuBarLyricsFontFamily = "" }
        if settings.lyricsWindowFontFamily == font.familyName { settings.lyricsWindowFontFamily = "" }
        if settings.lyricsWindowMiniFontFamily == font.familyName { settings.lyricsWindowMiniFontFamily = "" }
    }

    // MARK: - 启动时注册

    private func registerAll() {
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files {
            if url.lastPathComponent.hasPrefix(Self.stagingPrefix) {
                try? fm.removeItem(at: url)
            } else if CustomFontFile.isSupported(url) {
                register(url)
            }
        }
        refresh()
    }

    /// 注册单个文件并返回它的族名;失败(文件损坏、根本不是字体)返回 nil。
    @discardableResult
    private func register(_ url: URL) -> String? {
        var registerError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registerError) else {
            logger.error("register \(url.lastPathComponent, privacy: .public) failed — \(String(describing: registerError), privacy: .public)")
            return nil
        }
        registered.insert(url.lastPathComponent)
        return CustomFontFile.familyName(ofFontAt: url)
    }

    private func unregister(_ url: URL) {
        var unregisterError: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &unregisterError)
        registered.remove(url.lastPathComponent)
    }

    private func refresh() {
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let entries = files
            .filter { CustomFontFile.isSupported($0) && registered.contains($0.lastPathComponent) }
            .compactMap { url -> (fileName: String, family: String)? in
                guard let family = CustomFontFile.familyName(ofFontAt: url) else { return nil }
                return (fileName: url.lastPathComponent, family: family)
            }
        fonts = CustomFontFile.groupByFamily(entries).map { ImportedFont(familyName: $0.family, fileNames: $0.fileNames) }
        availableFamilies = CustomFontFile.availableFamilyNames()
    }
}

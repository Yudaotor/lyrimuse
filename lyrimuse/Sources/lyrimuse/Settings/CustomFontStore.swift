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
@MainActor
final class CustomFontStore: ObservableObject {
    static let shared = CustomFontStore()

    /// 一款已导入的字体:磁盘上的文件名 + Core Text 注册后读回的族名。
    struct ImportedFont: Identifiable, Equatable {
        let fileName: String
        let familyName: String
        var id: String { fileName }
    }

    /// 按族名排序,给 `FontFamilyPicker` 展示用;删除按钮按 `fileName` 操作。
    @Published private(set) var fonts: [ImportedFont] = []

    enum ImportError: Error {
        /// 扩展名不是 .ttf / .otf。
        case unsupportedFormat
        /// 选中的文件读不出来(权限、文件已被移走等)。
        case unreadable
        /// 复制到本地成功,但 Core Text 认不出这是一份有效的字体。
        case invalidFont
    }

    private static let allowedExtensions: Set<String> = ["ttf", "otf"]

    private let fm = FileManager.default
    private var directory: URL { LyrimusePaths.configFile("fonts") }

    private init() {
        registerAll()
    }

    // MARK: - 导入 / 删除(设置页调用)

    /// 把一个本地字体文件收进这个 App 自己的目录并注册。同名文件直接覆盖——重新导入同一款
    /// 字体是常见操作(换一份修过的文件),不该在磁盘上滚雪球攒出好几份同名文件。
    @discardableResult
    func importFont(from url: URL) throws -> ImportedFont {
        let ext = url.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else { throw ImportError.unsupportedFormat }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            // 先反注册旧的一份,避免同一个文件名短暂地对应两次注册。
            var unregisterError: Unmanaged<CFError>?
            CTFontManagerUnregisterFontsForURL(dest as CFURL, .process, &unregisterError)
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.copyItem(at: url, to: dest)
        } catch {
            logger.error("importFont: copy failed — \(String(describing: error), privacy: .public)")
            throw ImportError.unreadable
        }
        guard let familyName = register(dest) else {
            try? fm.removeItem(at: dest)
            throw ImportError.invalidFont
        }
        let imported = ImportedFont(fileName: dest.lastPathComponent, familyName: familyName)
        refresh()
        return imported
    }

    /// 反注册并删除。先反注册再删文件——反过来的话,万一删除中途失败,会留下一个
    /// "文件没了但 Core Text 仍然认得"的悬空注册。
    ///
    /// 删除后如果这款字体正被悬浮歌词/灵动岛选中,不用在这里特意处理:`Font.overlayFont`
    /// 本来就是"族名找不到就显式落回系统字体",不会崩、也不会显示错误的字。
    func remove(_ font: ImportedFont) {
        let url = directory.appendingPathComponent(font.fileName)
        var unregisterError: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &unregisterError)
        try? fm.removeItem(at: url)
        refresh()
    }

    // MARK: - 启动时注册

    private func registerAll() {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in files where Self.allowedExtensions.contains(url.pathExtension.lowercased()) {
            register(url)
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
        return familyName(of: url)
    }

    private func familyName(of url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }

    private func refresh() {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            fonts = []
            return
        }
        fonts = files
            .filter { Self.allowedExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> ImportedFont? in
                guard let family = familyName(of: url) else { return nil }
                return ImportedFont(fileName: url.lastPathComponent, familyName: family)
            }
            .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }
}

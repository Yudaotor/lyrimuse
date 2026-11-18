import AppKit
import LyrimuseCore
import SwiftUI
import UniformTypeIdentifiers

// 字体选择器:系统装了什么就能选什么,外加用户自己导入的 .ttf / .otf。
//
// 之前这里是一个只有 7 款的精选下拉(拉丁 4 + 中文 3)。精选当初是为了避开
// "252 个字体族全塞进一个 Menu 根本没法用"这个问题,代价是想用别的字体就完全没有出路。
// 常规做法是列全 + 搜索 + 每一行用它自己的字体渲染族名 —— 挑字体时最需要的信息就是
// 它长什么样,光看名字选不出来。
//
// 系统字体列表由 `FontFamilyCatalog` 在后台读一次、整个进程共用:这一趟要等 fontd,
// 不在主线程上做。新装的系统字体要等下次启动才出现在列表里,对一个字体选择器来说可以接受。
//
// 加「导入字体」:系统字体列表再全,也只能覆盖"已经装在
// 这台 Mac 上"的字体——用户想用一款只有文件、没装进系统的字体,原来完全没有出路。落地和
// 反注册都在 CustomFontStore,这里只多了一段「已导入」列表 + 底部常驻的「导入字体…」入口,
// 挑选体验跟系统字体一致(同样能搜、同样自己渲染族名)。
@MainActor
struct FontFamilyPicker: View {
    /// 空字符串 = 跟随系统字体。
    @Binding var selection: String

    /// 用户从本地文件导入的字体(见 CustomFontStore 头注)。跟系统字体列表并列展示在
    /// 同一个选择器里——对选字体这件事来说,一款字体是系统自带的还是自己导入的不该是
    /// 两套不同的操作路径。
    @ObservedObject private var customFonts = CustomFontStore.shared
    @ObservedObject private var catalog = FontFamilyCatalog.shared

    @State private var showingList = false
    @State private var query = ""
    @State private var importError: String?

    /// 系统字体族快照还没读好时,系统字体区只列选中的那一款,下面跟一个转圈。导入字体启动时就注册了,也在快照里,
    /// 而且删掉之后快照不会变 —— 所以列出来之前再按 `CustomFontStore` 过一遍(见 `filtered`)。
    private var systemFamilies: [String] { catalog.snapshot?.families ?? [selection] }

    /// 中文字体的族名是英文的("PingFang SC"),但用户多半想按中文名找。两个都拿来匹配(`FontFamilySearch`)。
    private func localizedName(of family: String) -> String? { catalog.snapshot?.localizedNames[family] }

    /// 系统字体区:排除导入字体(它们在上面的「已导入」区,带删除键)和已经不存在的族(本次运行里删掉的导入字体)。
    private var filtered: [String] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        let system = systemFamilies.filter { !customFonts.isImported($0) && customFonts.isAvailable($0) }
        guard !keyword.isEmpty else { return system }
        return system.filter { FontFamilySearch.matches(query: keyword, family: $0, localizedName: localizedName(of: $0)) }
    }

    private var filteredCustomFonts: [CustomFontStore.ImportedFont] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return customFonts.fonts }
        return customFonts.fonts.filter { FontFamilySearch.matches(query: keyword, family: $0.familyName, localizedName: nil) }
    }

    /// 族名怎么显示给人看:空串是"跟随系统字体",其余直接用族名。
    ///
    /// static 而不是只留下面那个私有计算属性:悬浮歌词编辑台的工具栏要在
    /// 「Aa 字形…」按钮上显示同一截摘要(见 OverlayStyleSummary.text),而那个位置手里
    /// 只有一个字符串、构造不出这个 View。"空串 = 系统字体"这条规则只能有一处 ——
    /// 抄一份的话,以后把哨兵值从空串换成别的,漏改的那处会显示成一个空白按钮。
    /// 选中的族名此刻没有字体可用时带上「（未安装）」:几处摘要(编辑台工具栏、歌词窗口、菜单栏)跟这个选择器的
    /// 按钮说同一句话 —— 原来摘要照常显示族名,点开的选择器却标着未安装。
    static func displayName(for family: String) -> String {
        if family.isEmpty { return L10n.t("系统字体") }
        return CustomFontStore.shared.isAvailable(family) ? family : String(format: L10n.t("%@（未安装）"), family)
    }

    /// 选中的族名此刻没有字体可用(换机后没带过来 / 在别处删掉了):标「未安装」,按钮上用系统字体显示。
    private var selectionMissing: Bool { !customFonts.isAvailable(selection) }

    private var currentLabel: String { Self.displayName(for: selection) }

    var body: some View {
        Button {
            query = ""
            importError = nil
            showingList = true
        } label: {
            HStack(spacing: 5) {
                // 按钮上就用选中的那款字体显示它自己的名字,不用点开也知道现在是什么样。
                Text(currentLabel)
                    .font(selection.isEmpty || selectionMissing ? .system(size: 13) : .custom(selection, size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 190, alignment: .trailing)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        // 外观同玻璃下拉(`SettingsGlassMenuPicker` 的 compact 档):同一浮层里下面那行「粗细」就是它。
        .buttonStyle(SettingsGlassHoverButtonStyle(isOpen: showingList))
        .settingsCardBackground(cornerRadius: 14)
        .fixedSize()
        .popover(isPresented: $showingList, arrowEdge: .bottom) { picker }
        // 按钮一出现就开始在后台读,点开时多半已经读好。
        .onAppear { catalog.load() }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("搜索字体"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        row(family: "", label: L10n.t("系统字体"))
                        Divider().padding(.vertical, 2)
                    }
                    if !filteredCustomFonts.isEmpty {
                        ForEach(filteredCustomFonts) { font in
                            ImportedFontRow(
                                font: font,
                                isSelected: font.familyName == selection,
                                onSelect: {
                                    selection = font.familyName
                                    showingList = false
                                },
                                onDelete: {
                                    // 五处字体设置里仍指向这一族的,由 remove 一起退回系统字体。
                                    customFonts.remove(font)
                                }
                            )
                        }
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(filtered, id: \.self) { family in
                        row(family: family, label: family)
                    }
                    if catalog.snapshot == nil {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    } else if filtered.isEmpty && filteredCustomFonts.isEmpty {
                        Text(L10n.t("无匹配的字体"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }
            Divider()
            importRow
        }
        .frame(width: 260, height: 350)
    }

    /// 常驻在列表底部的「导入字体…」——不放进 ScrollView,免得字体一多就要滚到底才找得到。
    private var importRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: importFont) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L10n.t("导入字体…"))
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.glassListRow)
            .foregroundStyle(.secondary)
            if let importError {
                Text(importError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// 弹原生文件面板选 .ttf / .otf,可多选。跟设置页「从文件导入…」(SettingsView
    /// .pickConfigFileToImport)同一套做法:先选、面板一关就地校验,不搞"确认后才发现选错"。
    private func importFont() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf"),
        ].compactMap { $0 }
        panel.prompt = L10n.t("导入")
        panel.message = L10n.t("选择 .ttf 或 .otf 字体文件，可多选")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        importError = nil
        var failureCount = 0
        var unreadableCount = 0
        for url in panel.urls {
            do {
                try customFonts.importFont(from: url)
            } catch CustomFontStore.ImportError.unreadable {
                failureCount += 1
                unreadableCount += 1
            } catch {
                failureCount += 1
            }
        }
        switch CustomFontFile.importSummary(failed: failureCount, total: panel.urls.count, unreadable: unreadableCount) {
        case .allImported:
            return
        case .allUnreadable:
            importError = L10n.t("导入失败：无法读取所选文件，可能尚未下载到本机或无读取权限")
        case .allFailed:
            importError = L10n.t("导入失败：不是有效的 .ttf / .otf 字体文件")
        case .someFailed(let n):
            importError = String(format: L10n.plural("%@ 个文件导入失败，其余已导入", count: n), "\(n)")
        }
    }

    private func row(family: String, label: String) -> some View {
        Button {
            selection = family
            showingList = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(family == selection ? 1 : 0)
                VStack(alignment: .leading, spacing: 0) {
                    // 每一行用这一款字体本身渲染 —— 这才是挑字体时真正需要看到的东西。
                    Text(label)
                        .font(family.isEmpty ? .system(size: 13) : .custom(family, size: 13))
                        .lineLimit(1)
                    if let localized = localizedName(of: family) {
                        Text(localized)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.glassListRow)
    }
}

/// 系统字体族列表:第一次要时在后台读(`SystemFontFamilies.read`),读好回主线程发布一次,整个进程共用。
/// 族名和本地化名一起发布,选单只整体换一次。见 04 章决策 105。
@MainActor
final class FontFamilyCatalog: ObservableObject {
    static let shared = FontFamilyCatalog()

    @Published private(set) var snapshot: SystemFontFamilies.Snapshot?
    private var loading = false

    private init() {}

    func load() {
        guard snapshot == nil, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = SystemFontFamilies.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let catalog = FontFamilyCatalog.shared
                    catalog.snapshot = snapshot
                    catalog.loading = false
                }
            }
        }
    }
}

/// 「已导入」区的一行:跟系统字体那行(`FontFamilyPicker.row`)长得像,多一个 hover 才露出
/// 的删除按钮。独立成 struct 才能让 hover 状态是这一行自己的 `@State`,不必每次 hover 进出
/// 都让整个选择器重新求值——跟 `AccountLinkingTab.PendingListenRow` 同一个理由、同一套做法
/// (删除按钮常驻槽位、只切 opacity,不然按钮一出现整行宽度会抖)。
private struct ImportedFontRow: View {
    let font: CustomFontStore.ImportedFont
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(isSelected ? 1 : 0)
                    Text(font.familyName)
                        .font(.custom(font.familyName, size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.glassListRow)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help(L10n.t("删除此导入的字体（不可恢复）"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onHover { inside in isHovered = inside }
    }
}

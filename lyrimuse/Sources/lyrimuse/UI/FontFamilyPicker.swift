import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 字体选择器:系统装了什么就能选什么,外加用户自己导入的 .ttf / .otf。
//
// 之前这里是一个只有 7 款的精选下拉(拉丁 4 + 中文 3)。精选当初是为了避开
// "252 个字体族全塞进一个 Menu 根本没法用"这个问题,代价是想用别的字体就完全没有出路。
// 常规做法是列全 + 搜索 + 每一行用它自己的字体渲染族名 —— 挑字体时最需要的信息就是
// 它长什么样,光看名字选不出来。
//
// 列表本身缓存成 static:availableFontFamilies 这一趟要问系统要几百个族名,不该每次
// 重绘都跑一遍。新装的系统字体要等下次启动才出现在列表里,对一个字体选择器来说可以接受。
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

    @State private var showingList = false
    @State private var query = ""
    @State private var importError: String?

    private static let families: [String] = NSFontManager.shared.availableFontFamilies
        // 点号开头的是系统内部字体(.AppleSystemUIFont 这类),不该出现在给人看的选单里。
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    /// 中文字体的族名是英文的("PingFang SC"),但用户多半想按中文名找。两个都拿来匹配。
    private static let localizedNames: [String: String] = {
        var map: [String: String] = [:]
        for family in families {
            // localizedName(forFamily:face:) 返回的是非可选 String,拿不到本地化名时
            // 直接回族名本身,所以判据是"跟族名不同"而不是"有没有值"。
            let localized = NSFontManager.shared.localizedName(forFamily: family, face: nil)
            if localized != family { map[family] = localized }
        }
        return map
    }()

    private var filtered: [String] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return Self.families }
        return Self.families.filter { family in
            family.localizedCaseInsensitiveContains(keyword)
                || (Self.localizedNames[family]?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    private var filteredCustomFonts: [CustomFontStore.ImportedFont] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return customFonts.fonts }
        return customFonts.fonts.filter { $0.familyName.localizedCaseInsensitiveContains(keyword) }
    }

    /// 族名怎么显示给人看:空串是"跟随系统字体",其余直接用族名。
    ///
    /// static 而不是只留下面那个私有计算属性:悬浮歌词编辑台的工具栏要在
    /// 「Aa 文字…」按钮上显示同一截摘要(见 OverlayStyleSummary.text),而那个位置手里
    /// 只有一个字符串、构造不出这个 View。"空串 = 系统字体"这条规则只能有一处 ——
    /// 抄一份的话,以后把哨兵值从空串换成别的,漏改的那处会显示成一个空白按钮。
    static func displayName(for family: String) -> String {
        family.isEmpty ? L10n.t("系统字体") : family
    }

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
                    .font(selection.isEmpty ? .system(size: 13) : .custom(selection, size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingList, arrowEdge: .bottom) { picker }
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
                                    // 删的这款正被这个选择器选中就退回系统字体——不退的话按钮上会
                                    // 留着一个再也选不出来的族名(渲染路径 Font.overlayFont 本身
                                    // 会显式落回系统字体、不会崩,但按钮标签是直接 .custom(selection)
                                    // 渲染的,删完不退会显示成一款查无此字的幽灵字体)。
                                    if selection == font.familyName { selection = "" }
                                    customFonts.remove(font)
                                }
                            )
                        }
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(filtered, id: \.self) { family in
                        row(family: family, label: family)
                    }
                    if filtered.isEmpty && filteredCustomFonts.isEmpty {
                        Text(L10n.t("没有匹配的字体"))
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
            .buttonStyle(.plain)
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
        for url in panel.urls {
            do {
                _ = try customFonts.importFont(from: url)
            } catch {
                failureCount += 1
            }
        }
        guard failureCount > 0 else { return }
        importError = failureCount == panel.urls.count
            ? L10n.t("导入失败：不是有效的 .ttf / .otf 字体文件")
            : String(format: L10n.t("%@ 个文件导入失败，其余已导入"), "\(failureCount)")
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
                    if let localized = Self.localizedNames[family] {
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
        .buttonStyle(.plain)
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
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help(L10n.t("删除这款导入的字体（不可恢复）"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onHover { inside in isHovered = inside }
    }
}

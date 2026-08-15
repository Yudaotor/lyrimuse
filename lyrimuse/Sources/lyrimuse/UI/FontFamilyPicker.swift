import AppKit
import SwiftUI

// 字体选择器:系统装了什么就能选什么。
//
// 2026-08-15 之前这里是一个只有 7 款的精选下拉(拉丁 4 + 中文 3)。精选当初是为了避开
// "252 个字体族全塞进一个 Menu 根本没法用"这个问题,代价是想用别的字体就完全没有出路。
// 常规做法是列全 + 搜索 + 每一行用它自己的字体渲染族名 —— 挑字体时最需要的信息就是
// 它长什么样,光看名字选不出来。
//
// 列表本身缓存成 static:availableFontFamilies 这一趟要问系统要几百个族名,不该每次
// 重绘都跑一遍。新装的字体要等下次启动才出现在列表里,对一个字体选择器来说可以接受。
@MainActor
struct FontFamilyPicker: View {
    /// 空字符串 = 跟随系统字体。
    @Binding var selection: String

    @State private var showingList = false
    @State private var query = ""

    private static let families: [String] = NSFontManager.shared.availableFontFamilies
        // 点号开头的是系统内部字体(.AppleSystemUIFont 这类),不该出现在给人看的选单里。
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    /// 中文字体的族名是英文的("PingFang SC"),但用户多半想按中文名找。两个都拿来匹配。
    private static let localizedNames: [String: String] = {
        var map: [String: String] = [:]
        for family in families {
            // ⚠️ localizedName(forFamily:face:) 返回的是非可选 String,拿不到本地化名时
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

    private var currentLabel: String {
        selection.isEmpty ? L10n.t("系统字体") : selection
    }

    var body: some View {
        Button {
            query = ""
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
                    ForEach(filtered, id: \.self) { family in
                        row(family: family, label: family)
                    }
                    if filtered.isEmpty {
                        Text(L10n.t("没有匹配的字体"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }
        }
        .frame(width: 260, height: 320)
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

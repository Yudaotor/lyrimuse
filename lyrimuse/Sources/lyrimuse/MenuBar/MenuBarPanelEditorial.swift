import SwiftUI

/// 菜单栏面板点歌名 / 歌手名 / 专辑名翻出来的简介页:换掉面板下半部分(钮块网格和底栏),跟快捷设置同一个位置、
/// 同一种头部。正文复用灵动岛、歌词窗口那份 `EditorialNotesContent`。
///
/// 画在面板里,不另开一扇窗:面板点到别的窗口就收起(`MenuBarPanelController` 的局部点击监听),
/// 独立浮框或 popover 一点,面板连同它一起没了。
struct PanelEditorialPage: View {
    let card: EditorialCard
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                }
                .settingsGlassButtons()
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help(L10n.t("返回"))
                Text(card.kind.panelTitle).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            EditorialNotesContent(card: card, primary: .primary, secondary: .secondary, maxTextHeight: 260)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 玻璃卡,同正在播放卡和快捷设置。
        .menuBarPanelCardBackground(cornerRadius: 18)
    }
}

extension EditorialCard.Kind {
    /// 简介页头部的标题。
    var panelTitle: String {
        switch self {
        case .song: return L10n.t("歌曲简介")
        case .artist: return L10n.t("歌手简介")
        case .album: return L10n.t("专辑简介")
        }
    }
}

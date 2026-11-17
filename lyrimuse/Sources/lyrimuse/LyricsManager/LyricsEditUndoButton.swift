import LyrimuseCore
import SwiftUI

/// 回声旁边那颗「撤销」:玻璃小按钮,⌘Z。只在它出着的这几秒里占这个快捷键,之后输入框照常用它撤销打字。
/// 「搜索歌词…」、歌词管理详情页和多选面板、歌词窗口说明条共用,见 11 章决策 177、178、179。
struct LyricsEditUndoButton: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(L10n.t("撤销"), action: action)
            .controlSize(.small)
            .settingsGlassButtons()
            .fixedSize()
            .keyboardShortcut("z", modifiers: .command)
            .help(L10n.t("快捷键：⌘Z"))
            .disabled(disabled)
    }
}

extension LyricsEditUndo {
    /// 撤销失败时说的那一句,已经本地化。`batch`:撤的是多选那一笔。
    @MainActor
    static func failureText(_ result: EnrichEditChannel.Result, batch: Bool = false) -> String {
        switch failure(code: result.errorCode, localizedReason: result.errorIsLocalized ? result.error : nil, batch: batch) {
        case let .key(key): L10n.t(key)
        case let .format(format, reason): String(format: L10n.t(format), reason)
        }
    }
}

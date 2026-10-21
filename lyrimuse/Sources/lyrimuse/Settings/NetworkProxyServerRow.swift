import LyrimuseCore
import SwiftUI

/// 「代理」手动档的代理服务器输入:回车、离开输入框或这一行消失(切到别的档、关窗)时提交;写错了不改、行里提示,
/// 清空 = 没填(引擎当没有代理)。
struct NetworkProxyServerRow: View {
    @Binding var value: String
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        SettingsRow(icon: "server.rack", title: L10n.t("代理服务器"),
                    subtitle: problem ?? (value.isEmpty ? L10n.t("未填写时不使用代理") : nil)) {
            TextField("", text: $text, prompt: Text(verbatim: NetworkProxyServer.placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 170)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .settingsSearchFieldBackground(cornerRadius: 6)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: text) { _, _ in problem = nil }
                .accessibilityLabel(L10n.t("代理服务器"))
        }
        .onAppear { text = value }
        .onDisappear(perform: commit)
        .onChange(of: value) { _, newValue in text = newValue }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !NetworkProxyServer.isValid(trimmed) {
            problem = L10n.t("格式应为 主机:端口，可带 http:// 或 socks5:// 前缀")
            return
        }
        text = trimmed
        if trimmed != value { value = trimmed }
    }
}

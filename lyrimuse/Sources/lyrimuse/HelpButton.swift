import AppKit
import SwiftUI

// 统一的"?"帮助按钮——点击弹出一个 popover,放更详细的说明、可选再带一个跳官方文档的
// 链接。用来在设置页面里给"需要多一点背景知识才看得懂"的字段/开关提供按需展开的详情,
// 而不是把所有说明都写成常驻的 caption 挤占页面——常驻 caption 留给"一眼扫过就该知道"
// 的内容,这个按钮留给"需要的时候才点开看"的内容,比如各推送平台具体怎么申请 webhook
// 地址这种一次性操作指引。
struct HelpButton: View {
    let text: String
    var docTitle: String? = nil
    var docURL: URL? = nil

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout)
                if let docTitle, let docURL {
                    // 用 Button+NSWorkspace.shared.open 而不是 SwiftUI 的 Link——Link 对
                    // file:// scheme 的 URL 在这个 app 里点了没反应(docURL 指向本地 README.md
                    // 时完全无响应),NSWorkspace.shared.open 是这个项目里已经验证过能正常
                    // 工作的开文件/开链接方式(见 SettingsView.swift「打开歌词文件夹」),对
                    // http(s) 链接同样有效(交给默认浏览器打开),统一用这一种方式两种场景都覆盖。
                    Button(docTitle) { NSWorkspace.shared.open(docURL) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
    }
}

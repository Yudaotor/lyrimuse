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

/// 「一段文字 + 一个 ?」一组,**悬停(短延迟)或点问号**都能弹出说明。
///
/// 跟上面 HelpButton 的分工:那个只认点击,用在设置页里"需要时才展开"的长说明上;
/// 这个是给行内那种"扫一眼数字、想知道它怎么来的"场景 —— 悬停就该出,点一下也该出。
///
/// # 为什么不用 .help()
///
/// `.help()` 落到 NSView.toolTip,延迟由 NSToolTipManager **全局**控制,没有按控件调整的
/// API(唯一的调节点 NSInitialToolTipDelay 是 app 级的,会把整个 App 的所有 tooltip 一起
/// 改掉);而且它只认悬停,点击对它没有任何意义。用户报的两件事(出得太慢、想点一下就出)
/// 在 .help() 上一个都做不到,只能自己拿 onHover + popover 做。
struct QuickHelpLabel<Content: View>: View {
    let text: String
    @ViewBuilder let content: () -> Content

    /// 悬停多久才弹。系统 tooltip 没设过 NSInitialToolTipDelay 时实际观感约 2 秒,
    /// 这里取它的 1/4(2026-08-17 用户要求)。
    private static var hoverDelay: Duration { .milliseconds(500) }
    /// 鼠标移出后延这么久才收。不是手感修饰,是防抖:popover 弹出的一瞬间如果它盖住了
    /// 锚点,底下这个视图会立刻收到 onHover(false) —— 不缓冲一下就会"弹出即消失",
    /// 而且紧接着鼠标又在锚点上,循环闪烁。
    private static var closeGrace: Duration { .milliseconds(150) }

    @State private var isPresented = false
    /// 这次是点开的(而不是悬停出来的)。点开的要一直留着,等用户点别处才收 ——
    /// 悬停出来的那种鼠标一移开就该收,是两套语义。
    @State private var pinnedByClick = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 3) {
            content()
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.tertiary)
                // 图标本身太小不好点,把可点区域撑成整个方框。
                .contentShape(Rectangle())
                .onTapGesture {
                    hoverTask?.cancel()
                    pinnedByClick = true
                    isPresented = true
                }
        }
        // 悬停区是**整组**(数字 + 问号),跟改造前 .help() 挂的范围一致,不缩水;
        // 点击区只有问号 —— 这一组在候选列表的 List 行里,整组吃掉点击的话就点不动
        // 行选中了,而点一个问号图标本来就不像是在"选这一行"。
        .onHover { inside in
            hoverTask?.cancel()
            hoverTask = Task {
                try? await Task.sleep(for: inside ? Self.hoverDelay : Self.closeGrace)
                guard !Task.isCancelled else { return }
                if inside {
                    isPresented = true
                } else if !pinnedByClick {
                    isPresented = false
                }
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                // 分数明细是一列对齐的数字,等宽数字读起来才是一列。
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 280, alignment: .leading)
        }
        // 用户点别处把 popover 关掉之后,下一次悬停要能正常走"移开就收"那套。
        .onChange(of: isPresented) { _, shown in
            if !shown { pinnedByClick = false }
        }
        // @State 里的 Task 不会随视图消失自动取消,而这一组住在会滚动复用的 List 行里 ——
        // 不收的话,滚过去之后那条计时器还会醒来往一个已经不在屏幕上的行上设状态。
        .onDisappear { hoverTask?.cancel() }
    }
}

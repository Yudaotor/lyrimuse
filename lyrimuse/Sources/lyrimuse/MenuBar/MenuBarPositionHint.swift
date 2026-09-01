import AppKit
import SwiftUI

// 首次启动的一次性提示:「按住 ⌘ 拖拽这个图标,可以挪到菜单栏里想要的位置」。
//
// 背景(2026-09-01 用户要求"把图标挪到贴近系统图标的位置"):调研发现 macOS 没有公开
// API 能保证第三方状态栏图标的位置,苹果 HIG 原文明确说这该由用户决定、不该由 App
// 决定;历史上唯一的私有优先级接口在 10.6.3(2010)就已失效。唯一真正可靠、且是苹果
// 官方认可的手段就是引导用户自己 ⌘+拖拽——这个控制器就是那条引导,调用点见
// MenuBarStatusItem.start()。
//
// 只在 AppSettings.hasShownMenuBarPositionHint 从未置真时展示一次,之后永不再弹
// (跟 hasSeenChineseLyrics 反方向的一次性语义,见那个属性上的注释)。
//
// 用 NSPopover 而不是自建无边框窗口:结构照抄 MenuBarPanelController(同一个锚定
// 状态栏按钮 + transient 语义的场景),但这里的内容纯展示、不需要那边为一个持续可交互
// 面板准备的整套「点到别的 App 上收起 / cmd-tab 收起 / 切 Space 收起」的失焦监视器——
// 一次性提示多留几秒自己关掉就够了,常驻那三个监听器反而是不必要的开销。
@MainActor
final class MenuBarPositionHintController {
    private var popover: NSPopover?
    private var closeObserver: NSObjectProtocol?
    private var autoDismissWorkItem: DispatchWorkItem?

    /// 展示到期自动收起的秒数。给够时间让用户看完两行字、犯不着的话也不用手动点掉,
    /// 但又不会像常驻面板一样一直杵在那儿。
    private static let autoDismissSeconds: TimeInterval = 8

    func show(relativeTo button: NSStatusBarButton) {
        guard popover == nil else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let content = MenuBarPositionHintView(dismiss: { [weak pop] in pop?.performClose(nil) })
        pop.contentViewController = NSHostingController(rootView: content)
        popover = pop
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: pop, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.teardown() }
        }
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 跟 MenuBarPanelController 同一处修法(2026-08-31 那次"别的 App 全屏时面板打不开"):
        // NSPopover 自建窗口默认进不了别的 App 的全屏 Space,只能落在桌面 Space 上——
        // 一次性提示碰不上就直接看不见,补上这两位让它至少能出现在当前 Space。只能放在
        // show 之后:那个窗口是 show 内部现建的。
        pop.contentViewController?.view.window?.collectionBehavior
            .formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])

        let work = DispatchWorkItem { [weak pop] in pop?.performClose(nil) }
        autoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissSeconds, execute: work)
    }

    private func teardown() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        popover = nil
    }
}

private struct MenuBarPositionHintView: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("按住 ⌘ 拖拽这个图标，可以把它移动到菜单栏里你喜欢的位置。"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("知道了"), action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

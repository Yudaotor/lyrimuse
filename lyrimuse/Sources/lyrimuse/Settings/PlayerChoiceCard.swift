import AppKit
import LyrimuseCore
import SwiftUI

// 选播放器的图标卡片网格——2026-08-25 先在引导页"选择播放器"那一步用上,后来设置页
// "播放器"那张卡也换成同一套(用户要求两处排版和谐一致),所以从 OnboardingView.swift
// 挪出来独立成文件,两处共用同一个组件、同一份取图标逻辑,不重复维护。

/// 一张"选它"的图标卡片。图标按三级兜底取:
/// 1. 已安装就用 `AppIconResolver.icon(forBundleID:)` 查到的真实 App 图标(跟"正在播放"
///    面板来源角标同一个理由:2026-08-19 用户拍板"最好认,还不用自带任何商标素材",见
///    `PlaybackCoordinator.resolvedPlayerIcon`);
/// 2. 没装那个 App 就退回 `AppIconResolver.icon(bundledResourceName:)` 查随包打包的静态
///    品牌图(2026-09-02 新增,见该函数头注:用户反馈换一台没装全的机器,图标网格里一半
///    App 的图标"看着都跟坏了一样",根因是原来查不到就直接落到第 3 级占位,而品牌图标
///    本身不该受"这台机器装没装"影响);
/// 3. 两者都拿不到(比如 `PlaybackPlayer.auto`,或者以后新增播放器时暂时还没配打包图)
///    才退回 `PlaybackPlayer.tintColor` + `fallbackSymbolName` 这套纯色块占位,不留空白
///    方块。
///
/// ⚠️ 选中态"只用强调色描边+浅底、**不额外叠对号图标**"这条 2026-09-03 被推翻了(原注释
/// 原样留在下面 `ChoiceCardChrome` 里)。当初成立是因为这个网格是**单选**:页面上永远只有
/// 一张卡是亮的,靠对比就读得出来。改成多选之后要回答的问题变成"我到底勾了哪几个",纯颜色
/// 差异在色觉障碍/「增强对比度」下会整个失效,而且旁白用户完全无从得知 —— 所以现在选中态
/// 是"描边+浅底+右上角对号"三重表达,外加下面那条 `.isSelected` 无障碍特征。
struct PlayerChoiceCard: View {
    let player: PlaybackPlayer
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                PlayerIconView(player: player)
                Text(player.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.primary)
            }
            .choiceCardChrome(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        // 旁白要能读出"选没选中" —— `Button` 自带 `.isButton`,但选中与否此前只存在于
        // 描边颜色里,VoiceOver 读到的永远是"Apple Music,按钮",听不出勾没勾。
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}

/// 一个播放器的图标,**不带卡片外壳**——三级兜底的取图逻辑本体在这里,`PlayerChoiceCard`
/// 只是把它套进选项卡里。
///
/// 2026-09-03 从 `PlayerChoiceCard` 里抽出来:引导页收尾那一页要在正文里排一串小图标
/// (「你选的这几个播放器」),那里既没有选中态也不能点,套不进 `PlayerChoiceCard`;而这
/// 三级兜底(已装的真图标 → 随包品牌图 → 纯色块占位)是这个仓库反复调过的东西,照抄一份
/// 就等于开第二个漂移点——用户 2026-09-02 报过"换一台没装全的机器,图标网格里一半 App
/// 的图标看着都跟坏了一样",根因正是当时少了中间那一级。
struct PlayerIconView: View {
    let player: PlaybackPlayer
    var size: CGFloat = 26
    @State private var resolvedIcon: NSImage?

    var body: some View {
        Group {
            if let resolvedIcon {
                Image(nsImage: resolvedIcon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: player.fallbackSymbolName)
                    // 占位符号跟着尺寸缩放,不写死 15 —— 引导页收尾那页用的是 24pt。
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(player.tintColor,
                                in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            }
        }
        .onAppear(perform: loadRealIconIfAvailable)
    }

    // .auto 没有对应的 App,两级都不用查,直接落到纯色占位。
    private func loadRealIconIfAvailable() {
        guard player != .auto else { return }
        if let installed = AppIconResolver.icon(forBundleID: player.bundleIdentifier) {
            resolvedIcon = installed
        } else if let name = player.bundledIconResourceName {
            resolvedIcon = AppIconResolver.icon(bundledResourceName: name)
        }
    }
}

/// 选项卡片的外壳(圆角底 + 选中态的强调色描边/浅底)。2026-09-03 从 `PlayerChoiceCard`
/// 的 body 里提出来 —— 引导页那张「YouTube Music」网页平台卡要跟播放器卡**逐像素同款**
/// (它们并排在同一个网格里),两处各写一遍圆角/透明度就是下次调样式漏一处。
private struct ChoiceCardChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            // 右上角的对号 —— 见 `PlayerChoiceCard` 头注那条 2026-09-03 的推翻说明:多选之后
            // 光靠颜色表达不了"勾了哪几个"。`.overlay` 不参与布局,卡片高度/网格行数不变
            // (这一步没有 ScrollView,高度预算很紧,见 OnboardingView 里那几条约束)。
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        // 垫一层窗口底色,免得对号压在卡片描边上糊成一团。
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(4)
                }
            }
    }
}

extension View {
    fileprivate func choiceCardChrome(isSelected: Bool) -> some View {
        modifier(ChoiceCardChrome(isSelected: isSelected))
    }
}

/// 「网页播放器平台」的选项卡 —— 目前只有引导页「选择播放器」那一步用,摆在六张
/// `PlayerChoiceCard` 之后(2026-09-03,用户要求"这里也给我加上 youtube music 的选项")。
///
/// 为什么不能直接用 `PlayerChoiceCard`:YouTube Music **不是** `PlaybackPlayer` 的一个
/// case,它是浏览器里的网页播放器(`BrowserPositionProbe.supportedPlatforms`),对应的不是
/// 一个本地 App、也不写进 `features.players`,而是"配对哪个浏览器"这套完全不同的状态
/// (见 `BrowserPairing`)。硬塞成一个 `PlaybackPlayer` case 会让 bundleIdentifier /
/// collector 侧的 playerXxx 常量 / `soleExplicitPlayer` 那一串全都要为它开特例。
///
/// ⚠️ 卡片外壳走 `choiceCardChrome`,跟播放器卡同一份 —— 它们在同一个网格里并排,长得
/// 不一样就会被当成两种不同的控件。
struct WebPlatformChoiceCard: View {
    let icon: NSImage?
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                } else {
                    // 没走 build.sh 打包时(直接 swift build 跑)取不到随包图标,退回
                    // SF Symbol,别让图标位裸奔成空白 —— 同 PlayerChoiceCard 的第三级兜底。
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.primary)
            }
            .choiceCardChrome(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        // 同 `PlayerChoiceCard`:它俩并排在同一个网格里,无障碍表现也不该有差别。
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 引导页网格里第三行第一格那张占位卡(只在引导页用,设置页那张卡六个选项正好排满
/// 2 行,不需要它)——用户 2026-08-25 明确要求摆在这个位置(截图纠正过来的:第一次说
/// "加几个点"以为是指文案末尾,其实指的是六个真选项排完之后网格自己留出来的这一格)。
/// 不用 Button 包、没有选中态的描边/底色——虚线框 + 三个点的视觉语言故意跟六张真选项卡
/// 区分开,不会被当成"点了没反应的坏按钮"。
struct MorePlayersComingCard: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("•••")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 26)
            Text(L10n.t("陆续支持中"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
    }
}

import AppKit
import LyrimuseCore
import SwiftUI

// 选播放器的图标卡片网格——先在引导页"选择播放器"那一步用上,后来设置页
// "播放器"那张卡也换成同一套(两处排版和谐一致),所以从 OnboardingView.swift
// 挪出来独立成文件,两处共用同一个组件、同一份取图标逻辑,不重复维护。

/// 一张"选它"的图标卡片。图标按三级兜底取:
/// 1. 已安装就用 `AppIconResolver.icon(forBundleID:)` 查到的真实 App 图标(跟"正在播放"
///    面板来源角标同一个理由:"最好认,还不用自带任何商标素材",见
///    `PlaybackCoordinator.resolvedPlayerIcon`);
/// 2. 没装那个 App 就退回 `AppIconResolver.icon(bundledResourceName:)` 查随包打包的静态
///    品牌图(新增,见该函数头注:现象是换一台没装全的机器,图标网格里一半
///    App 的图标"看着都跟坏了一样",根因是原来查不到就直接落到第 3 级占位,而品牌图标
///    本身不该受"这台机器装没装"影响);
/// 3. 两者都拿不到(比如 `PlaybackPlayer.auto`,或者以后新增播放器时暂时还没配打包图)
///    才退回 `PlaybackPlayer.tintColor` + `fallbackSymbolName` 这套纯色块占位,不留空白
///    方块。
///
/// 选中态"只用强调色描边+浅底、**不额外叠对号图标**"这条被推翻了(原注释
/// 原样留在下面 `ChoiceCardChrome` 里)。当初成立是因为这个网格是**单选**:页面上永远只有
/// 一张卡是亮的,靠对比就读得出来。改成多选之后要回答的问题变成"我到底勾了哪几个",纯颜色
/// 差异在色觉障碍/「增强对比度」下会整个失效,而且旁白用户完全无从得知 —— 所以现在选中态
/// 是"描边+浅底+右上角对号"三重表达,外加下面那条 `.isSelected` 无障碍特征。
struct PlayerChoiceCard: View {
    let player: PlaybackPlayer
    let isSelected: Bool
    /// 没勾这一颗,但**勾着「自动识别」**,所以它照样会被识别。`MediaControlClient.fetchSnapshot`
    /// / collector `getState` 第一行都是「集合里含 auto 就走自动识别那条路」,auto 按超集处理,
    /// 具体勾选此时不参与"认哪几个"(见 docs 02)。这里只负责让界面把这件事说出来;卡片照样能勾。
    var isCoveredByAuto: Bool = false
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
            .choiceCardChrome(isSelected: isSelected, isCoveredByAuto: isCoveredByAuto)
        }
        .buttonStyle(.plain)
        // 旁白要能读出"选没选中" —— `Button` 自带 `.isButton`,但选中与否此前只存在于
        // 描边颜色里,VoiceOver 读到的永远是"Apple Music,按钮",听不出勾没勾。
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // 虚线框和角标都是视觉,旁白读不到 —— 这句让它也能听到"这颗由自动识别接管"。
        .accessibilityValue(isCoveredByAuto ? L10n.t("由「自动识别」接管——取消「自动识别」后才只认你勾选的播放器") : "")
        // 指向就能读到那句话,不必先点一下才发现"取消勾选好像没用"。设置页和引导页都是普通
        // 窗口,`.help()` 在这两处是真能弹出来的(悬浮窗那排按钮不行,那是另一回事)。
        .help(isCoveredByAuto ? L10n.t("由「自动识别」接管——取消「自动识别」后才只认你勾选的播放器") : "")
    }

}

/// 一个播放器的图标,**不带卡片外壳**——三级兜底的取图逻辑本体在这里,`PlayerChoiceCard`
/// 只是把它套进选项卡里。
///
/// 从 `PlayerChoiceCard` 里抽出来:引导页收尾那一页要在正文里排一串小图标
/// (「你选的这几个播放器」),那里既没有选中态也不能点,套不进 `PlayerChoiceCard`;而这
/// 三级兜底(已装的真图标 到 随包品牌图 到 纯色块占位)是这个仓库反复调过的东西,照抄一份
/// 就等于开第二个漂移点——表现过"换一台没装全的机器,图标网格里一半 App
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

/// 「可勾选的图标块」共用的一套配色 —— 播放器卡、网页平台卡、「播放器联动」那排芯片全走这里。
///
/// 选中态**不拿强调色铺底**。这些网格都是多选,而设置页默认就是"全勾"的形状:强调色底 +
/// 强调色描边 + 强调色对号三层同色一叠,六张卡一起亮起来整页就糊成一块蓝(实机采样过,卡片底
/// #DBE2ED、比周围底色暗 17 阶,整片网格读起来是一块色块而不是六个选项)。
///
/// 口径改成**用明度表达选中、用强调色点缀**:选中的块比周围**亮**(像抬起来的一张纸),
/// 强调色只留在 1pt 描边和右上角那枚角标这两处小面积上。这样"勾了哪几个"比原来更好读——
/// 亮/暗的对比不依赖色相,「增强对比度」和色觉障碍下都还在(这正是这个网格当初补对号要解决的
/// 同一件事,见 `PlayerChoiceCard` 头注)。
///
/// 深浅外观两档分开,不要合并成一个 opacity:深色外观下"提亮"要靠白色叠加,浅色外观下同一个
/// 数值会直接烧成纯白。
enum ChoiceHighlight {
    static func fill(isSelected: Bool, isHovering: Bool = false, scheme: ColorScheme) -> Color {
        if isSelected { return Color.white.opacity(scheme == .dark ? 0.13 : 0.9) }
        let base: Double = scheme == .dark ? 0.07 : 0.04
        return Color.primary.opacity(isHovering ? base + 0.04 : base)
    }

    /// 没选中的块也有一条极淡的描边 —— 它背后那张玻璃卡跟它的明度差只有几格(见
    /// `settingsCardBackground` 里量出来的 1~5/255),不描边的话浅色外观下这些"格子"的边界
    /// 基本看不见,网格读起来是一团浮着的图标而不是一排可勾选的卡。
    static func stroke(isSelected: Bool, scheme: ColorScheme) -> Color {
        if isSelected { return Color.accentColor.opacity(scheme == .dark ? 0.75 : 0.6) }
        return Color.primary.opacity(scheme == .dark ? 0.12 : 0.08)
    }

    static func lineWidth(isSelected: Bool) -> CGFloat { isSelected ? 1 : 0.5 }

    /// 选中块底下那层很轻的投影,"抬起来"这件事的另一半。
    ///
    /// 深色外观返回 `.clear`:深色底上的黑色投影只会把卡片周围糊脏一圈,提亮本身已经把层次
    /// 表达完了。
    static func selectedShadow(isSelected: Bool, scheme: ColorScheme) -> Color {
        guard isSelected, scheme != .dark else { return .clear }
        return Color.black.opacity(0.07)
    }
}

/// 选项卡片的外壳(圆角底 + 选中态的强调色描边/浅底)。从 `PlayerChoiceCard`
/// 的 body 里提出来 —— 引导页那张「YouTube Music」网页平台卡要跟播放器卡**逐像素同款**
/// (它们并排在同一个网格里),两处各写一遍圆角/透明度就是下次调样式漏一处。
private struct ChoiceCardChrome: ViewModifier {
    let isSelected: Bool
    /// 见 `PlayerChoiceCard.isCoveredByAuto`。只有播放器卡会传 true —— 网页平台卡
    /// (YouTube Music)走的是"配对哪个浏览器"那套状态,跟 `features.players` 无关。
    var isCoveredByAuto: Bool = false
    /// 整张卡是不是一个可点的按钮。设置页「网页播放器」那张卡不是(卡面上只有头像和「+」
    /// 各自可点),给它加悬停高亮等于骗用户"整块都能点"。
    var highlightsOnHover: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 11, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                shape.fill(ChoiceHighlight.fill(isSelected: isSelected,
                                                isHovering: isHovering,
                                                scheme: colorScheme))
                    .shadow(color: ChoiceHighlight.selectedShadow(isSelected: isSelected, scheme: colorScheme),
                            radius: 2, y: 1)
            )
            .overlay(shape.strokeBorder(ChoiceHighlight.stroke(isSelected: isSelected, scheme: colorScheme),
                                        lineWidth: ChoiceHighlight.lineWidth(isSelected: isSelected)))
            // 「由自动识别接管」= **虚线**强调色描边:虚线读作"不是一个你勾上的选项",
            // 加上强调色正好表达"它在生效,但不是你勾的"。
            //
            // 刻意**不做成"浅一点的实心对号"**:那和真选中态只差一个透明度,在「增强
            // 对比度」/色觉障碍下两者会糊成同一个东西,而这张网格才因为
            // "纯颜色差异表达不了勾了哪几个"补上对号(见 PlayerChoiceCard 头注)——再拿
            // 透明度去区分两种状态等于把那次的教训原地推翻。
            .overlay {
                if isCoveredByAuto, !isSelected {
                    shape.strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.5 : 0.4),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            // 右上角的对号 —— 见 `PlayerChoiceCard` 头注那条的推翻说明:多选之后
            // 光靠颜色表达不了"勾了哪几个"。`.overlay` 不参与布局,卡片高度/网格行数不变
            // (这一步没有 ScrollView,高度预算很紧,见 OnboardingView 里那几条约束)。
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        // 垫一层窗口底色,免得对号压在卡片描边上糊成一团。
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(5)
                } else if isCoveredByAuto {
                    // 对号的位置换成"自动"那味儿的角标。用 `sparkles` 而不是「自动识别」卡
                    // 自己那个 `wand.and.stars`:后者的字形明显扁,`Circle()` 背景会按短边
                    // 内切成一个小圆躲在魔杖中间,看着像画坏了;`sparkles` 近似正方,跟上面
                    // 那枚对号共用同一套尺寸/垫底/内边距,两种角标位对位。
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.65))
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(5)
                }
            }
            // 悬停只改底色不改描边:描边是"选没选中"的载体,让它跟着鼠标变会把两件事混在一起。
            .onHover { hovering in
                guard highlightsOnHover else { return }
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

extension View {
    /// 凡是摆进"选播放器"这类图标网格的卡片都走这里,别在调用点另写一份圆角/底色/描边 ——
    /// 设置页「网页播放器」卡和这边的播放器卡并排在同一页,样式各写一份下次调色就会漏一处
    /// (它们曾经就是两份)。
    func choiceCardChrome(isSelected: Bool,
                          isCoveredByAuto: Bool = false,
                          highlightsOnHover: Bool = true) -> some View {
        modifier(ChoiceCardChrome(isSelected: isSelected,
                                  isCoveredByAuto: isCoveredByAuto,
                                  highlightsOnHover: highlightsOnHover))
    }
}

/// 「网页播放器平台」的选项卡 —— 目前只有引导页「选择播放器」那一步用,摆在六张
/// `PlayerChoiceCard` 之后("这里也给我加上 youtube music 的选项")。
///
/// 为什么不能直接用 `PlayerChoiceCard`:YouTube Music **不是** `PlaybackPlayer` 的一个
/// case,它是浏览器里的网页播放器(`BrowserPositionProbe.supportedPlatforms`),对应的不是
/// 一个本地 App、也不写进 `features.players`,而是"配对哪个浏览器"这套完全不同的状态
/// (见 `BrowserPairing`)。硬塞成一个 `PlaybackPlayer` case 会让 bundleIdentifier /
/// collector 侧的 playerXxx 常量 / `soleExplicitPlayer` 那一串全都要为它开特例。
///
/// 卡片外壳走 `choiceCardChrome`,跟播放器卡同一份 —— 它们在同一个网格里并排,长得
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
/// 2 行,不需要它)——位置是固定的:六个真选项排完之后,网格自己留出来的这一格。
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
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
    }
}

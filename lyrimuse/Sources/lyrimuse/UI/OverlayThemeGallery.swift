import SwiftUI

// 「主题」浮层与抽屉「主题」组里的预览卡:每套配色画成一张小卡,用它自己的已唱 / 未唱 / 背景 /
// 描边颜色写一行示例歌词,点一下就套用。管理逻辑(存、改名、覆盖、删除)在 OverlayThemeSettingsRows。

enum ThemeGalleryMetrics {
    /// 自适应列宽:编辑台「主题」浮层(720pt)一行排下全部 7 个内置预设;抽屉是整列宽(上限 600pt),排 6 列。
    /// 固定 7 列:七套内置主题一行排完(自适应列在抽屉的卡片宽度下只放得下 6 格,「霓虹」会单独掉到第二行)。
    /// 窄到一格放不下示例字时,示例字自己缩(`ThemeSampleLyric` 的 minimumScaleFactor)。
    static let columns = Array(repeating: GridItem(.flexible(minimum: 60, maximum: 150), spacing: 8, alignment: .top), count: 7)
    static let rowSpacing: CGFloat = 10
    static let tileHeight: CGFloat = 46
    static let cornerRadius: CGFloat = 8
}

/// 预览卡的底:一块从浅到深的斜向渐变,充当"桌面"。白字在深的一侧读得出、黑字在浅的一侧读得出,
/// 描边款两侧都读得出 —— 描边的价值在卡上直接看得见。不跟系统深浅色走:悬浮歌词压在壁纸上,
/// 跟设置窗是什么外观无关。
private struct ThemeTileBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.89, green: 0.90, blue: 0.92), Color(red: 0.29, green: 0.31, blue: 0.36)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// 一行示例歌词:前半截用已唱色、后半截用未唱色(跟随封面的那一半画多色渐变,它没有固定颜色),背景色画成歌词后面的圆角底(开了毛玻璃就先垫一层
/// 材质、背景色叠在上面当着色,跟悬浮窗同一个叠法),描边走悬浮窗同一个 `lyricsTextStroke`。
private struct ThemeSampleLyric: View {
    let theme: ColorTheme

    private var halves: (sung: String, unsung: String) {
        let sample = L10n.t("歌词预览")
        let splitIndex = sample.index(sample.startIndex, offsetBy: sample.count / 2)
        return (String(sample[..<splitIndex]), String(sample[splitIndex...]))
    }

    var body: some View {
        let halves = halves
        HStack(spacing: 0) {
            Text(halves.sung).foregroundStyle(
                Self.style(hex: theme.foregroundColorHex, followsCover: theme.followsCoverArt, fallback: .white))
            Text(halves.unsung).foregroundStyle(
                Self.style(hex: theme.karaokeUnsungColorHex, followsCover: theme.karaokeUnsungFollowsCoverArt,
                           fallback: .white.opacity(0.35)))
        }
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .lineLimit(1)
        .lyricsTextStroke(
            theme.textStrokeEnabled,
            color: Color(hexWithAlpha: theme.textStrokeColorHex, fallback: .black.opacity(0.65))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            ZStack {
                if theme.backgroundGlass { shape.fill(theme.glassIntensity.material) }
                shape.fill(Color(hexWithAlpha: theme.backgroundColorHex, fallback: .clear))
            }
        }
    }

    private static func style(hex: String, followsCover: Bool, fallback: Color) -> AnyShapeStyle {
        guard followsCover else { return AnyShapeStyle(Color(hexWithAlpha: hex, fallback: fallback)) }
        return AnyShapeStyle(LinearGradient(
            colors: ThemeSwatch.coverHintColors.map { Color(nsColor: $0) },
            startPoint: .leading, endPoint: .trailing))
    }
}

/// 一张预览卡:上面是示例歌词,下面是主题名。当前生效的那张描强调色边框、名字加粗。
/// `badge` 是叠在预览右上角的小图标(「自定义」那张用它标出"点一下可以存下来");`help` 不给就用主题名。
struct ThemePreviewCard: View {
    let theme: ColorTheme
    let isCurrent: Bool
    var badge: String?
    var help: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    ThemeTileBackdrop()
                    ThemeSampleLyric(theme: theme)
                }
                .frame(maxWidth: .infinity)
                .frame(height: ThemeGalleryMetrics.tileHeight)
                .clipShape(RoundedRectangle(cornerRadius: ThemeGalleryMetrics.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ThemeGalleryMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isCurrent ? 2 : 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.accentColor))
                            .padding(4)
                    }
                }
                Text(theme.name)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help ?? (theme.followsCoverArt ? "\(theme.name) · \(L10n.t("跟随封面"))" : theme.name))
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var borderColor: Color {
        if isCurrent { return .accentColor }
        return Color.primary.opacity(isHovering ? 0.35 : 0.12)
    }
}

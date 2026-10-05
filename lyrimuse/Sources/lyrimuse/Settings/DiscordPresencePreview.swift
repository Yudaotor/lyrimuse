import AppKit
import LyrimuseCore
import SwiftUI

/// Discord 页顶上的预览:照 Discord 桌面版深色主题的样子画两处——服务器成员名单里你那一行(头像、名字,下面是绿色音符
/// 加「状态里显示」选的那一项),以及别人点开你资料卡时「当前动态」那一块(「正在听 应用名」、封面、歌名、歌手、专辑、进度)。
/// 尺寸、字号、颜色见 12 章决策 36。内容就是此刻会发出去的那一份(`DiscordPresence.activity`);没在放歌、或者这首不会显示时
/// 用一份示例。不联网:封面用 App 手上那张,没有公网封面时跟 Discord 一样显示应用图标;头像用 `DiscordAvatarStore` 已经取到的
/// 那张。画面不随开关、暂停、暂时隐藏变淡,这些情况只写在下面那行说明里。设置窗口看不见时停表。
struct DiscordPresencePreview: View {
    @ObservedObject private var discord = DiscordPresenceController.shared
    @ObservedObject private var avatars = DiscordAvatarStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.previewHostVisible) private var previewHostVisible

    private enum Palette {
        static let window = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1E / 255)
        static let popout = Color(red: 0x24 / 255, green: 0x24 / 255, blue: 0x29 / 255)
        static let memberText = Color(red: 0x81 / 255, green: 0x82 / 255, blue: 0x8A / 255)
        static let headerText = Color(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFB / 255)
        static let cardText = Color(red: 0xEF / 255, green: 0xEF / 255, blue: 0xF1 / 255)
        static let menuIcon = Color(red: 0xAB / 255, green: 0xAC / 255, blue: 0xB2 / 255)
        static let green = Color(red: 0x45 / 255, green: 0xA3 / 255, blue: 0x66 / 255)
        static let progressTrack = Color(red: 151 / 255, green: 151 / 255, blue: 159 / 255).opacity(0.16)
        /// 暂停小图的底色,跟传到 Discord 的那张同色。
        static let pausedBadge = Color(red: 0x4E / 255, green: 0x50 / 255, blue: 0x58 / 255)
    }

    /// 资料卡那一块的宽度,和它最高时(有专辑、有进度条)的高度。舞台按最高的留位置,暂停时进度条没了页面也不跳。
    private static let cardWidth: CGFloat = 268
    private static let cardTallestHeight: CGFloat = 110
    /// 小图跟封面之间那一圈弹窗底色的宽度。
    private static let smallImageRing: CGFloat = 2

    private struct Model {
        let activity: DiscordActivity
        let application: DiscordPresence.Application
        /// 有公网封面时用 App 手上那张;nil = 跟 Discord 一样显示应用图标。
        let artwork: NSImage?
        let progress: (elapsedMs: Int64, totalMs: Int64)?
        let caption: String

        var activityName: String { activity.name ?? application.registeredName }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !previewHostVisible)) { context in
            let model = makeModel(now: context.date)
            VStack(spacing: SectionPreviewMetrics.captionSpacing) {
                stage(model)
                Text(model.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: SectionPreviewMetrics.captionHeight)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func makeModel(now: Date) -> Model {
        let playback = PlaybackCoordinator.shared
        let live = discord.previewTrack(now: now)
        let pausedKept = live != nil && !playback.isPlayingSmoothed && settings.discordKeepWhenPaused
        let track = live ?? sampleTrack
        let smallImage: DiscordPresence.SmallImage? = pausedKept
            ? .paused(L10n.t("已暂停"))
            : DiscordPresence.smallImage(for: settings.discordBadge, applicationID: track.applicationID)
        let activity = DiscordPresence.activity(track, statusLine: settings.discordStatusDisplay, now: now,
                                                smallImage: smallImage)
        let caption: String
        if !settings.discordPresenceEnabled {
            caption = L10n.t("预览 · 开关关着，Discord 上不会显示")
        } else if let hiddenUntil = discord.hiddenUntil {
            caption = String(format: L10n.t("预览 · 已暂时隐藏，%@ 恢复"), DiscordPresenceController.restoreTimeText(hiddenUntil))
        } else if live == nil {
            caption = playback.title.isEmpty ? L10n.t("预览 · 没在放歌，先用示例") : L10n.t("预览 · 现在这首不会显示到 Discord")
        } else if !playback.isPlayingSmoothed && !settings.discordKeepWhenPaused {
            caption = String(format: L10n.t("预览 · 暂停 %d 秒后从 Discord 上清掉"), Int(DiscordPresence.pauseGrace))
        } else {
            caption = L10n.t("预览 · 好友在 Discord 里看到的样子")
        }
        return Model(
            activity: activity,
            application: DiscordPresence.application(forApplicationID: activity.applicationID),
            artwork: live != nil && activity.assets != nil ? playback.highResArtworkImage ?? playback.artworkImage : nil,
            progress: DiscordPresence.progress(of: activity, now: now),
            caption: caption)
    }

    /// 示例那份给一个占位的封面地址(不会去取),好让它跟有封面的歌一样带上小图;画的时候没有封面图,显示应用图标。
    private var sampleTrack: DiscordPresence.Track {
        DiscordPresence.Track(
            title: L10n.t("歌名"), artist: L10n.t("歌手"),
            playerName: DiscordPresence.Application.appleMusic.registeredName,
            coverURL: URL(string: "https://lyrimuse.invalid/sample.jpg"),
            positionMs: 83_000, durationMs: 269_000,
            applicationID: DiscordPresence.applicationID(forBundleID: PlaybackPlayer.appleMusic.bundleIdentifier,
                                                         webPlatformID: nil))
    }

    private var userName: String {
        if case .connected(let user?) = discord.status { return user.displayName }
        return L10n.t("你")
    }

    // MARK: - 舞台

    private func stage(_ model: Model) -> some View {
        HStack(alignment: .top, spacing: 16) {
            section(L10n.t("服务器成员名单")) { memberRow(model) }
                .frame(maxWidth: .infinity, alignment: .leading)
            section(L10n.t("资料卡 · 当前动态")) { activityCard(model) }
                .frame(width: Self.cardWidth)
        }
        .frame(minHeight: Self.cardTallestHeight + 20, alignment: .top)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.window))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.memberText)
            content()
        }
    }

    /// 成员名单里那一行:头像带在线点,名字,下面一行是绿色音符加状态文字,没有「正在听」三个字。
    private func memberRow(_ model: Model) -> some View {
        HStack(spacing: 12) {
            avatar(size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(userName)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                HStack(spacing: 4) {
                    Text("\u{266B}")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.green)
                    Text(DiscordPresence.statusText(of: model.activity))
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(height: 16)
            }
            .foregroundStyle(Palette.memberText)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// 资料卡里「当前动态」那一块:标题「正在听 应用名」带右上角「···」,下面是 60pt 封面和歌名、歌手、专辑,在放时文字列底下
    /// 一行时间和 2pt 进度条。专辑(large_text)只在有公网封面时才发,没有时那一行不画。封面、歌名、歌手、专辑有链接时能点,
    /// 专辑跟封面共用 `large_url`,见 12 章决策 37、38。封面右下角压着小图(`smallImage`)。
    private func activityCard(_ model: Model) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(String(format: L10n.t("正在听 %@"), model.activityName))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.headerText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.menuIcon)
                    .frame(width: 16, height: 16)
            }
            .frame(height: 16)
            HStack(alignment: .top, spacing: 8) {
                PreviewLink(url: Self.url(model.activity.assets?.largeURL)) { _ in
                    largeImage(model)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .overlay(alignment: .bottomTrailing) { smallImage(model) }
                VStack(alignment: .leading, spacing: 0) {
                    PreviewLink(url: Self.url(model.activity.detailsURL)) { hovered in
                        Text(model.activity.details)
                            .font(.system(size: 14, weight: .semibold))
                            .underline(hovered)
                            .frame(height: 18)
                    }
                    PreviewLink(url: Self.url(model.activity.stateURL)) { hovered in
                        Text(model.activity.state)
                            .font(.system(size: 12))
                            .underline(hovered)
                            .frame(height: 16)
                    }
                    if let album = model.activity.assets?.largeText {
                        PreviewLink(url: Self.url(model.activity.assets?.largeURL)) { hovered in
                            Text(album)
                                .font(.system(size: 12))
                                .underline(hovered)
                                .frame(height: 16)
                        }
                    }
                    if let progress = model.progress {
                        progressRow(progress)
                            .padding(.top, 4)
                    }
                }
                .foregroundStyle(Palette.cardText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.popout))
    }

    // MARK: - 零件

    private func avatar(size: CGFloat) -> some View {
        Group {
            if case .connected = discord.status, let image = avatars.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                accountIconBadge(.discord, size: size, cornerRadius: 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(Palette.green)
                .frame(width: size * 0.3125, height: size * 0.3125)
                .overlay(Circle().stroke(Palette.window, lineWidth: 3))
                .offset(x: 2, y: 2)
        }
    }

    @ViewBuilder private func largeImage(_ model: Model) -> some View {
        if let artwork = model.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            applicationIcon(model, size: 60)
        }
    }

    /// 封面右下角的小图:24pt 圆形,压出封面 4pt,外面一圈弹窗底色;有 `small_url` 时能点,指向时出 `small_text`。
    @ViewBuilder private func smallImage(_ model: Model) -> some View {
        if let assets = model.activity.assets, let image = assets.smallImage {
            PreviewLink(url: Self.url(assets.smallURL)) { _ in
                smallBadge(image, model)
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .padding(Self.smallImageRing)
                    .background(Circle().fill(Palette.popout))
            }
            .help(assets.smallText ?? "")
            .offset(x: 4 + Self.smallImageRing, y: 4 + Self.smallImageRing)
        }
    }

    /// 小图本身:暂停图标照传到 Discord 的那张画(灰底、两道白竖条);Lyrimuse 角标用 App 图标,播放器角标用那个应用的图标
    /// (`discordApplicationIcon`),都放大一点,让圆里没有图标四周的透明边。
    @ViewBuilder private func smallBadge(_ image: String, _ model: Model) -> some View {
        if image == DiscordPresence.pausedBadgeURL {
            ZStack {
                Palette.pausedBadge
                HStack(spacing: 2.7) {
                    RoundedRectangle(cornerRadius: 0.8).fill(Color.white).frame(width: 3.2, height: 9.8)
                    RoundedRectangle(cornerRadius: 0.8).fill(Color.white).frame(width: 3.2, height: 9.8)
                }
            }
        } else if image != DiscordPresence.lyrimuseBadgeURL, let icon = discordApplicationIcon(model.application) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.22)
        } else {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.22)
        }
    }

    private func applicationIcon(_ model: Model, size: CGFloat) -> some View {
        Group {
            if let icon = discordApplicationIcon(model.application) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                accountIconBadge(.discord, size: size, cornerRadius: size * 0.22)
            }
        }
        .frame(width: size, height: size)
    }

    private func progressRow(_ progress: (elapsedMs: Int64, totalMs: Int64)) -> some View {
        HStack(spacing: 8) {
            Text(Self.clock(progress.elapsedMs))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.progressTrack)
                    Capsule()
                        .fill(Palette.headerText)
                        .frame(width: geometry.size.width * CGFloat(Double(progress.elapsedMs) / Double(max(progress.totalMs, 1))))
                }
                .frame(height: 2)
                .frame(maxHeight: .infinity)
            }
            Text(Self.clock(progress.totalMs))
        }
        .font(.system(size: 12).monospacedDigit())
        .frame(height: 16)
    }

    private static func url(_ string: String?) -> URL? {
        string.flatMap { URL(string: $0) }
    }

    /// Discord 的写法:分钟也补两位(00:51),过一小时带小时。
    private static func clock(_ ms: Int64) -> String {
        let seconds = Int(max(0, ms / 1000))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// 预览里能点的那几处:有链接时指上去出手形、`label` 拿到 true(文字据此加下划线),点了用浏览器打开;没链接时就是普通的字或图。
/// 手形压没压过记在 `cursorPushed`,移开或视图消失时弹回。
private struct PreviewLink<Label: View>: View {
    let url: URL?
    @ViewBuilder let label: (_ hovered: Bool) -> Label
    @State private var hovered = false
    @State private var cursorPushed = false

    var body: some View {
        if let url {
            label(hovered)
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(url) }
                .onHover { inside in
                    hovered = inside
                    syncCursor()
                }
                .onDisappear {
                    if cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                }
        } else {
            label(false)
        }
    }

    private func syncCursor() {
        if hovered, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !hovered, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

/// 这个 Discord 应用的图标,跟开发者后台传的同一套来路:播放器装了用它的 App 图标,没装用随包的品牌图;YouTube Music
/// 用随包的那张,Lyrimuse 用自己的图标。
@MainActor
func discordApplicationIcon(_ application: DiscordPresence.Application) -> NSImage? {
    let player: PlaybackPlayer
    switch application {
    case .lyrimuse: return NSApp.applicationIconImage
    case .youtubeMusic: return WebPlatformIcon.image("youtubeMusic")
    case .appleMusic: player = .appleMusic
    case .spotify: player = .spotify
    case .qqMusic: player = .qqMusic
    case .netease: player = .netease
    case .kugou: player = .kugou
    case .soda: player = .soda
    case .kkbox: player = .kkbox
    case .amazonMusic: player = .amazonMusic
    }
    return AppIconResolver.icon(forBundleID: player.bundleIdentifier)
        ?? player.bundledIconResourceName.flatMap { AppIconResolver.icon(bundledResourceName: $0) }
}

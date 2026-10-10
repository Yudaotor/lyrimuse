import AppKit
import LyrimuseCore
import SwiftUI

/// 「选择播放器」这一块:播放器图标网格,「自动识别」是网格里跟播放器并列的一张卡,可以跟具体
/// 播放器一起勾。设置页「播放器」卡和引导页「选择播放器」那一步共用,两处必须长得一样。
///
/// 勾着「自动识别」时认哪几个不看具体勾选(auto 按超集处理,见 docs 02),没单独勾上的卡显示成
/// 「由自动识别接管」(`PlayerChoiceCard.isCoveredByAuto`);具体播放器照样能勾,取消「自动识别」
/// 之后就只认勾上的那几个。
///
/// 摆哪几张卡、切模式时选中集合怎么变,都在 `PlayerPickerLayout`(有 selftest);这里只管画、
/// 落盘和顺带要「自动化」权限。
struct PlayerPicker<Trailing: View>: View {
    @ObservedObject var features: FeatureSettingsStore
    /// 设置页用:5 列方块格(`PlayerCompactTile`),不画「自动识别」那一格(它在卡头当总开关)。引导页不传。
    var compact = false
    /// 追加在播放器卡之后、「更多播放器」之前的卡(引导页那张 YouTube Music)。
    @ViewBuilder let trailing: () -> Trailing

    // @State 的初值表达式在**每次**构造这个结构体时都会求一次(SwiftUI 只是丢掉结果),父视图每重算一次就逐个
    // 播放器查一遍 LaunchServices;走一份几秒内有效的缓存。真正刷新仍是下面的 refreshInstalled。
    @State private var installed: Set<PlaybackPlayer> = InstalledPlayersCache.current()
    @State private var showsMore = false

    init(features: FeatureSettingsStore, compact: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.features = features
        self.compact = compact
        self.trailing = trailing
    }

    private var isAutoDetect: Bool { features.players.contains(.auto) }

    var body: some View {
        let tiles = PlayerPickerLayout.tiles(order: PlaybackPlayer.displayOrder,
                                             selected: features.players,
                                             installed: installed)
        Group {
            if compact { compactGrid(tiles) } else { regularGrid(tiles) }
        }
        .onAppear(perform: refreshInstalled)
        // 设置页开着的时候用户去装了一个播放器,切回来就该出现在网格里。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshInstalled()
        }
    }

    /// 引导页那套:3 列大卡,「自动识别」是其中一张。
    private func regularGrid(_ tiles: PlayerPickerLayout.Tiles) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(tiles.main) { player in
                PlayerChoiceCard(player: player,
                                 isSelected: features.players.contains(player),
                                 isCoveredByAuto: isAutoDetect && !features.players.contains(player),
                                 isInstalled: installed.contains(player)) {
                    toggle(player)
                }
            }
            trailing()
            // 「自动识别」排在具体播放器(以及引导页那张 YouTube Music)之后。从 displayOrder 里取、
            // 不裸写 `.auto`:displayOrder 里有什么就摆什么,这条对整张网格成立。
            ForEach(PlaybackPlayer.displayOrder.filter { $0 == .auto }) { player in
                PlayerChoiceCard(player: player, isSelected: isAutoDetect) {
                    toggle(player)
                }
            }
            if !tiles.more.isEmpty {
                MorePlayersCard(count: tiles.more.count) { showsMore = true }
                    .popover(isPresented: $showsMore, arrowEdge: .bottom) {
                        morePlayersPopover
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 紧凑模式的网格:5 列方块格,末尾一格「更多播放器(N)」点开同一个弹层。列数用 `compactColumns`,
    /// 设置页另外两组(网页、已信任)也用它,三组的格子一样大。
    private func compactGrid(_ tiles: PlayerPickerLayout.Tiles) -> some View {
        LazyVGrid(columns: Self.compactColumns, spacing: 8) {
            ForEach(tiles.main) { player in
                PlayerCompactTile(player: player,
                                  isSelected: features.players.contains(player),
                                  isCoveredByAuto: isAutoDetect,
                                  isInstalled: installed.contains(player)) {
                    toggle(player)
                }
            }
            trailing()
            if !tiles.more.isEmpty {
                Button { showsMore = true } label: {
                    CompactTileLabel(title: String(format: L10n.t("更多播放器（%d）"), tiles.more.count), dimmed: true) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                    }
                    .compactTileChrome(isSelected: false)
                }
                .buttonStyle(.plain)
                .help(L10n.t("这台 Mac 上未安装的播放器"))
                .popover(isPresented: $showsMore, arrowEdge: .bottom) {
                    morePlayersPopover
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 设置页方块格的列。窗口默认宽度下一格约 108pt,「Amazon Music」「Microsoft Edge」放得下。
    static var compactColumnCount: Int { 5 }
    static var compactColumns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: compactColumnCount) }

    /// 「更多播放器」弹出的那一小格网格。每次重新求 `tiles`:勾上一个它就挪进主网格,
    /// 这里跟着少一格;一格都不剩时锚点那张卡消失,弹层随之收起。
    private var morePlayersPopover: some View {
        let more = PlayerPickerLayout.tiles(order: PlaybackPlayer.displayOrder,
                                            selected: features.players,
                                            installed: installed).more
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("以下播放器尚未安装，可提前选择，安装后自动生效"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 10), count: min(3, max(more.count, 1))),
                      spacing: 10) {
                ForEach(more) { player in
                    PlayerChoiceCard(player: player,
                                     isSelected: false,
                                     isInstalled: false) {
                        toggle(player)
                    }
                }
            }
            HStack(spacing: 4) {
                Text(L10n.t("未找到要使用的播放器？"))
                    .foregroundStyle(.secondary)
                Link(L10n.t("在 GitHub 提交请求"), destination: FeedbackLinks.playerRequestURL(appVersion: FeedbackReporter.appVersion()))
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
    }

    /// 切换一个具体播放器。「最后一个不能取消」的判断在 `FeatureSettingsStore.togglePlayer`;
    /// **勾上**的那一下顺带把「自动化」权限要出来(分寸见 `requestOnSelect` 头注),取消不触发。
    private func toggle(_ player: PlaybackPlayer) {
        togglePlayerSelection(player, features: features)
    }

    private func refreshInstalled() {
        let now = InstalledPlayersCache.refresh()
        if now != installed { installed = now }
    }
}

extension PlayerPicker where Trailing == EmptyView {
    init(features: FeatureSettingsStore, compact: Bool = false) {
        self.init(features: features, compact: compact) { EmptyView() }
    }
}

/// 网格末尾「更多播放器(N)」那一格:点开是没装的内置播放器。外壳走 `choiceCardChrome`,
/// 跟旁边的播放器卡同款,只是没有选中态。
struct MorePlayersCard: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                Text(String(format: L10n.t("更多播放器（%d）"), count))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.secondary)
            }
            .choiceCardChrome(isSelected: false)
        }
        .buttonStyle(.plain)
        .help(L10n.t("这台 Mac 上未安装的播放器"))
    }
}

/// 已安装播放器的查询结果,几秒内复用(泛型结构体不能有静态存储属性,所以放在文件级)。
@MainActor
enum InstalledPlayersCache {
    private static var value: Set<PlaybackPlayer>?
    private static var at = Date.distantPast
    private static let ttl: TimeInterval = 5

    static func current() -> Set<PlaybackPlayer> {
        if let value, Date().timeIntervalSince(at) < ttl { return value }
        return refresh()
    }

    static func refresh() -> Set<PlaybackPlayer> {
        let now = PlayerPickerLayout.installedPlayers()
        value = now
        at = Date()
        return now
    }
}

/// 勾上 / 取消一个播放器(含「自动识别」)。设置页卡头那颗「自动识别」开关也走这里,跟网格里点格子同一条路。
@MainActor
func togglePlayerSelection(_ player: PlaybackPlayer, features: FeatureSettingsStore) {
    let wasSelected = features.players.contains(player)
    features.togglePlayer(player)
    guard !wasSelected, features.players.contains(player) else { return }
    PlayerAutomationPermissions.shared.requestOnSelect(justEnabled: player)
}

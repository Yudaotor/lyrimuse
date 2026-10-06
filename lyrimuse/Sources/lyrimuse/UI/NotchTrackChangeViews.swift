import AppKit
import LyrimuseCore
import SwiftUI

/// 换歌翻牌:新歌名从刘海里掉出来的那一条。挂在顶行下面(`NotchLyricsView`):关着歌词行时占卡片多长出来的
/// `NotchMetrics.trackDropHeight`,开着时盖在歌词行上。条子本身定宽定高、自己裁掉上沿以上,字是从刘海底边拉出来的。
///
/// 整条像抽屉一样拉出来、原路缩回去:字的位置和透明度只看条子拉开了多少(`NotchTrackDropReveal`)。关着歌词行时卡片下沿
/// 用同一对弹簧(`revealAnimation` / `retractAnimation`),字的下沿跟着卡片下沿走,不在卡片里另外晃。收回时 `drop` 已经是 nil,
/// 接着画刚才那条。停着时又换了一首(`NotchTrackDrop.replacing`):条子不动,旧的往下掉出去、新的从顶上落进来(`NotchTrackDropRoll`)。
///
/// 字一律白(歌名 96%、歌手 62%),颜色只给歌名前那枚音符;字底下垫一层淡淡的暗晕,封面有亮块时字不糊进底里。
/// 暗晕原地跟着淡入淡出,不跟着字走。
struct NotchTrackDropStrip: View {
    let drop: NotchTrackDrop?
    /// 音符的颜色(`NotchLyricsView.trackDropNoteTint`)。
    let noteTint: Color
    let width: CGFloat
    let height: CGFloat
    /// false = 「减弱动态效果」开着:原地淡入淡出,不拉不推。
    let animated: Bool

    /// 条子拉出来 / 缩回去。关着歌词行时卡片长高 / 缩回也是这两条(`NotchWindowRoot.cardAnimation`),两处必须是同一个值。
    static let revealAnimation = Animation.spring(response: 0.38, dampingFraction: 0.72)
    static let retractAnimation = Animation.spring(response: 0.32, dampingFraction: 1.0)
    private static let reducedMotionFade = Animation.easeInOut(duration: 0.2)

    /// 最近一次露出来的那条,收回时接着画。
    @State private var lastShown: NotchTrackDrop?

    var body: some View {
        let progress: CGFloat = drop == nil ? 0 : 1
        ZStack {
            scrim.modifier(NotchTrackDropReveal(progress: progress, travel: 0))
            NotchTrackDropRoll(drop: drop ?? lastShown, travel: height, animated: animated) { title, artist in
                line(title: title, artist: artist)
            }
            .modifier(NotchTrackDropReveal(progress: progress, travel: animated ? height : 0))
        }
        .frame(width: width, height: height)
        .clipped()
        .animation(animated ? (drop == nil ? Self.retractAnimation : Self.revealAnimation) : Self.reducedMotionFade,
                   value: drop == nil)
        .allowsHitTesting(false)
        .onChange(of: drop) { _, new in
            if let new { lastShown = new }
        }
    }

    /// 椭圆暗晕:横向半径是条子宽的 58%、纵向是条子高的 120%,中心略偏下。
    private var scrim: some View {
        EllipticalGradient(stops: [
            .init(color: .black.opacity(0.42), location: 0),
            .init(color: .black.opacity(0.18), location: 0.55),
            .init(color: .clear, location: 1),
        ])
        .frame(width: width * 1.16, height: height * 2.4)
        .offset(y: height * 0.05)
        .accessibilityHidden(true)
    }

    /// 歌名、歌手各自按需截断:一个短一个长时短的那个整个留着,两个都长时各让一半;音符和圆点不截。
    private func line(title: String, artist: String) -> some View {
        HStack(spacing: 5) {
            // 音符用 Text 包着画,别写成单独的 Image(systemName:):单独的符号图在这棵树里跟着整行往上收、离条子上沿三四 pt 时
            // 会整枚不画(歌名照常),包进 Text 就跟歌名一起走(见 05 章决策 68)。
            Text(Image(systemName: "music.note"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(noteTint)
                .animation(.easeInOut(duration: 0.35), value: noteTint)
                .fixedSize()
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
            if !artist.isEmpty {
                Text(verbatim: "·")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
                    .accessibilityHidden(true)
                Text(artist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        .padding(.horizontal, 14)
        .frame(width: width, height: height)
        .accessibilityElement(children: .combine)
    }
}

/// 条子拉开了多少(0 收着、1 拉满):字往上缩进 `travel`,不透明度按 `NotchTrackDropRules.revealOpacity`。
/// 位置和透明度每一帧都从 `progress` 算;跟卡片高度走同一条弹簧时,字的下沿就一直贴着卡片下沿。
private struct NotchTrackDropReveal: ViewModifier, Animatable {
    var progress: CGFloat
    let travel: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(y: -travel * (1 - progress))
            .opacity(NotchTrackDropRules.revealOpacity(progress: Double(progress)))
    }
}

/// 停着时又换了一首(`NotchTrackDrop.replacing`):旧的往下掉出去,新的稍后从顶上落进来。只在带着 `replacing` 的那条换上来时
/// 播一遍;条子拉出来、缩回去时不跑关键帧、只换字。两条都按 `id` 换身份、不做过渡,换字不会叠出上一条的残影。
private struct NotchTrackDropRoll<Line: View>: View {
    let drop: NotchTrackDrop?
    /// 新的那条从多高落下来(条子高)。
    let travel: CGFloat
    let animated: Bool
    @ViewBuilder let line: (_ title: String, _ artist: String) -> Line

    /// 旧的那条往下掉多远。
    private static var fall: CGFloat { 7 }

    var body: some View {
        // 只在推出旧行时触发:关键帧跑着时内容每一帧都要重建一遍(见 05 章决策 68)。
        KeyframeAnimator(initialValue: NotchTrackDropRollState.settled, trigger: drop?.replacing == nil ? -1 : drop?.id ?? -1) { roll in
            ZStack {
                if let drop, let gone = drop.replacing {
                    line(gone.title, gone.artist)
                        .offset(y: animated ? Self.fall * roll.outgoing : 0)
                        .opacity(1 - min(1, max(0, roll.outgoing)))
                        .id(drop.id)
                        .transition(.identity)
                }
                if let drop {
                    line(drop.title, drop.artist)
                        .offset(y: animated ? -travel * (1 - roll.incoming) : 0)
                        .opacity(min(1, max(0, roll.incoming)))
                        .id(drop.id)
                        .transition(.identity)
                }
            }
        } keyframes: { _ in
            let start: Double = drop?.replacing == nil ? 1 : 0
            KeyframeTrack(\.outgoing) {
                MoveKeyframe(start)
                LinearKeyframe(1, duration: 0.12, timingCurve: .easeIn)
            }
            KeyframeTrack(\.incoming) {
                MoveKeyframe(start)
                LinearKeyframe(start, duration: 0.07)
                SpringKeyframe(1, spring: Spring(response: 0.36, dampingRatio: 0.9))
            }
        }
    }
}

private struct NotchTrackDropRollState {
    /// 新的那条落进来的进度:0 藏在顶上,1 落到位。
    var incoming: Double
    /// 旧的那条掉出去的进度:0 在原位,1 掉出去看不见。
    var outgoing: Double

    static let settled = NotchTrackDropRollState(incoming: 1, outgoing: 1)
}

/// 耳朵里的一张图,按对象身份比较(同一张封面的两次解码是两个对象,是不是同一张画面另由指纹判)。
struct NotchArtworkRef: Equatable {
    let image: NSImage

    static func == (lhs: NotchArtworkRef, rhs: NotchArtworkRef) -> Bool { lhs.image === rhs.image }
}

/// 两张封面是不是同一张画面(`ArtworkFingerprint`)。指纹按图对象缓存最近几张:每次换歌最多算两三张,
/// 每张要把整张图解一遍再缩到 8×8,所以新图一到就先在后台算(`prefetch`)。
@MainActor
enum NotchArtworkFingerprints {
    private static var cache: [(image: NSImage, print: ArtworkFingerprint?)] = []
    /// 正在后台算的图。持有强引用:`ObjectIdentifier` 在对象释放后会被新对象复用。
    private static var pending: [ObjectIdentifier: NSImage] = [:]

    static func same(_ lhs: NotchArtworkRef, _ rhs: NotchArtworkRef) -> Bool {
        guard let a = fingerprint(lhs.image), let b = fingerprint(rhs.image) else { return false }
        return a.isSamePicture(as: b)
    }

    /// 新图一到就调:指纹在后台算好放进缓存,真要翻的那一刻(揭晓新歌、歌名掉下来同一拍)直接命中,
    /// 不在下拉动画开头那几帧里缩图(05 章决策 70)。主线程只取一次 CGImage;还没算完就走 `fingerprint`
    /// 当场算,结果一样。
    static func prefetch(_ image: NSImage) {
        let id = ObjectIdentifier(image)
        guard pending[id] == nil, !cache.contains(where: { $0.image === image }),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        pending[id] = image
        Task.detached(priority: .userInitiated) {
            let made = ArtworkFingerprint(image: source)
            await MainActor.run { store(made, for: id) }
        }
    }

    private static func store(_ made: ArtworkFingerprint?, for id: ObjectIdentifier) {
        guard let image = pending.removeValue(forKey: id), !cache.contains(where: { $0.image === image }) else { return }
        remember(image, made)
    }

    private static func fingerprint(_ image: NSImage) -> ArtworkFingerprint? {
        if let hit = cache.first(where: { $0.image === image }) { return hit.print }
        let made = image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { ArtworkFingerprint(image: $0) }
        remember(image, made)
        return made
    }

    private static func remember(_ image: NSImage, _ print: ArtworkFingerprint?) {
        cache.insert((image, print), at: 0)
        if cache.count > 4 { cache.removeLast(cache.count - 4) }
    }
}

/// 换歌翻牌:耳朵里那枚封面,一直开着、不看设置。左耳这一枚连广告时的喇叭一起画,
/// 广告结束、新封面到了,喇叭才能翻成封面。什么时候翻、什么时候原地换、什么时候先留着原来那一面,
/// 规则都在 Core `NotchArtworkFlipPlanner`;这里只执行。换歌后等灵动岛控制器揭晓了这一首(`isRevealed`)才翻,
/// 跟歌名掉下来同一拍。
///
/// 歌名或歌手变了才算换歌。广告结束、回到的还是进广告前那首(Kaset 的前贴片广告报的就是这首)不算换歌,广告期间到的
/// 封面当场就能翻上来(`NotchArtworkFlipPlanner.adBreakEnded`);别的进出广告照换歌算。
///
/// 翻的是封面本身(以它自己的中心为轴),外面那层占满耳朵的 frame 不跟着转。
struct NotchEarArtworkFlip<Artwork: View, AdIcon: View>: View {
    typealias Planner = NotchArtworkFlipPlanner<NotchArtworkRef>

    private let track: Track
    private let artworkImage: NSImage?
    private let highResImage: NSImage?
    private let overrideImage: NSImage?
    private let isAdBreak: Bool
    private let isRevealed: Bool
    private let alignment: Alignment
    /// false = 「减弱动态效果」开着:该翻的时候原地淡入。
    private let animated: Bool
    private let artwork: (NSImage) -> Artwork
    private let adIcon: () -> AdIcon

    @State private var planner: Planner
    @State private var front: Planner.Face
    @State private var back: Planner.Face?
    @State private var angle: Double = 0
    @State private var flipGeneration = 0
    /// 上一次看到的那几张图;换歌时它们就是旧图。
    @State private var previousImages: [NSImage]
    /// 进广告前最后一拍放的那首;广告结束时回到的还是它,就是这首的前贴片广告放完了。
    @State private var trackBeforeAd: Track?

    /// - Parameters:
    ///   - overrideImage: 盖过封面的那张(电台口白时的台标)。
    ///   - isAdBreak: 这一格此刻该画喇叭(只有左耳传 true)。
    ///   - isRevealed: 灵动岛控制器揭晓了此刻这一首(`NotchChromeSource.revealsTrack`)。
    init(title: String, artist: String, artworkImage: NSImage?, highResImage: NSImage?, overrideImage: NSImage?,
         isAdBreak: Bool, isRevealed: Bool, alignment: Alignment, animated: Bool,
         @ViewBuilder artwork: @escaping (NSImage) -> Artwork,
         @ViewBuilder adIcon: @escaping () -> AdIcon) {
        self.track = Track(title: title, artist: artist)
        self.artworkImage = artworkImage
        self.highResImage = highResImage
        self.overrideImage = overrideImage
        self.isAdBreak = isAdBreak
        self.isRevealed = isRevealed
        self.alignment = alignment
        self.animated = animated
        self.artwork = artwork
        self.adIcon = adIcon
        let target = Self.target(isAdBreak: isAdBreak, image: overrideImage ?? highResImage ?? artworkImage)
        _planner = State(initialValue: Planner(shown: target))
        _front = State(initialValue: target)
        _previousImages = State(initialValue: [artworkImage, highResImage, overrideImage].compactMap { $0 })
    }

    private struct Track: Equatable {
        let title: String
        let artist: String
    }

    private struct Input: Equatable {
        let track: Track
        let isAdBreak: Bool
        let isRevealed: Bool
        let artwork: ObjectIdentifier?
        let highRes: ObjectIdentifier?
        let override: ObjectIdentifier?
    }

    private enum FaceID: Hashable {
        case empty, adIcon, artwork(ObjectIdentifier)
    }

    private var input: Input {
        Input(track: track, isAdBreak: isAdBreak, isRevealed: isRevealed, artwork: artworkImage.map(ObjectIdentifier.init),
              highRes: highResImage.map(ObjectIdentifier.init), override: overrideImage.map(ObjectIdentifier.init))
    }

    private static func target(isAdBreak: Bool, image: NSImage?) -> Planner.Face {
        if isAdBreak { return .adIcon }
        return image.map { .artwork(NotchArtworkRef(image: $0)) } ?? .empty
    }

    private var currentTarget: Planner.Face {
        Self.target(isAdBreak: isAdBreak, image: overrideImage ?? highResImage ?? artworkImage)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            face(front)
                .id(faceID(front))
                .modifier(NotchFlipFace(angle: angle, isBack: false))
                .transition(.opacity)
            if let back {
                face(back)
                    .id(faceID(back))
                    .modifier(NotchFlipFace(angle: angle, isBack: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .onChange(of: input) { old, new in
            prefetchArtwork()
            react(from: old, to: new)
        }
        .task(id: planner.recheckAt) {
            guard let at = planner.recheckAt else { return }
            let wait = at.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            apply(planner.update(target: currentTarget, now: Date(), samePicture: { NotchArtworkFingerprints.same($0, $1) }))
        }
    }

    @ViewBuilder
    private func face(_ face: Planner.Face) -> some View {
        switch face {
        case .empty: Color.clear.frame(width: 0, height: 0)
        case .adIcon: adIcon()
        case .artwork(let ref): artwork(ref.image)
        }
    }

    private func faceID(_ face: Planner.Face) -> FaceID {
        switch face {
        case .empty: return .empty
        case .adIcon: return .adIcon
        case .artwork(let ref): return .artwork(ObjectIdentifier(ref.image))
        }
    }

    /// 新图一到就在后台先把翻牌要用的指纹和小封面算好(05 章决策 70),揭晓时直接命中缓存。
    private func prefetchArtwork() {
        for image in [artworkImage, highResImage, overrideImage].compactMap({ $0 }) {
            NotchArtworkFingerprints.prefetch(image)
            ArtworkThumbnailCache.prefetch(image)
        }
    }

    private func react(from old: Input, to new: Input) {
        let now = Date()
        if !old.isAdBreak, new.isAdBreak { trackBeforeAd = old.track }
        if old.isAdBreak, !new.isAdBreak, new.track == trackBeforeAd {
            planner.adBreakEnded(now: now)
        } else if old.track != new.track || old.isAdBreak != new.isAdBreak {
            planner.trackChanged(staleArtwork: previousImages.map { NotchArtworkRef(image: $0) }, now: now)
        }
        if new.isRevealed { planner.reveal() }
        previousImages = [artworkImage, highResImage, overrideImage].compactMap { $0 }
        apply(planner.update(target: currentTarget, now: now, samePicture: { NotchArtworkFingerprints.same($0, $1) }))
    }

    private func apply(_ transition: Planner.Transition?) {
        guard let transition else { return }
        let next = planner.shown
        commitFlip()
        switch transition {
        case .cut:
            withoutAnimation { front = next }
        case .fade:
            withAnimation(.easeInOut(duration: 0.25)) { front = next }
        case .flip:
            guard animated else {
                withAnimation(.easeInOut(duration: 0.25)) { front = next }
                return
            }
            flipGeneration &+= 1
            let generation = flipGeneration
            withoutAnimation {
                back = next
                angle = 0
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72), completionCriteria: .removed) {
                angle = 180
            } completion: {
                if generation == flipGeneration { commitFlip() }
            }
        }
    }

    /// 翻完(或翻到一半又来了下一次):背面那张换到正面、角度归零,画面不变。
    private func commitFlip() {
        guard let back else { return }
        withoutAnimation {
            front = back
            self.back = nil
            angle = 0
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

/// 翻牌的一面:绕竖轴转,转到一半之后这一面看不见(背面那张 −180° 起转,转完正好正着);转到侧面时稍微抬起、
/// 压暗一点。角度 0 时什么都不改。
private struct NotchFlipFace: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let tilt = abs(sin(angle * .pi / 180))
        let visible = isBack ? angle >= 90 : angle < 90
        return content
            .brightness(-0.3 * tilt)
            .rotation3DEffect(.degrees(isBack ? angle - 180 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(1 + 0.12 * tilt)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}

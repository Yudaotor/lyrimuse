import AppKit
import LyrimuseCore
import SwiftUI

/// 换歌翻牌:新歌名从刘海里掉出来的那一条。挂在顶行下面(`NotchLyricsView`):关着歌词行时占卡片多长出来的
/// `NotchMetrics.trackDropHeight`,开着时盖在歌词行上。`drop` 换一条(`id` 变)= 旧的往上收回去、新的从上面掉下来;
/// nil = 收回去。条子本身定宽定高、自己裁掉上沿以上,所以字是从刘海底边掉出来的。
///
/// 字一律白(歌名 96%、歌手 62%),颜色只给歌名前那枚音符;字底下垫一层淡淡的暗晕,封面有亮块时字不糊进底里。
struct NotchTrackDropStrip: View {
    let drop: NotchTrackDrop?
    /// 音符的颜色(`NotchLyricsView.trackDropNoteTint`)。
    let noteTint: Color
    let width: CGFloat
    let height: CGFloat
    /// false = 「减弱动态效果」开着:原地淡入淡出,不掉不弹。
    let animated: Bool

    var body: some View {
        ZStack {
            // 暗晕原地淡入淡出,不跟着字掉。
            scrim
                .opacity(drop == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: drop == nil)
            if let drop {
                line(drop)
                    .id(drop.id)
                    .transition(animated
                        ? .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                      removal: .move(edge: .top).combined(with: .opacity))
                        : .opacity)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .animation(animated ? .spring(response: 0.38, dampingFraction: 0.62) : .easeInOut(duration: 0.2),
                   value: drop?.id)
        .allowsHitTesting(false)
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
    private func line(_ drop: NotchTrackDrop) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "music.note")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(noteTint)
                .animation(.easeInOut(duration: 0.35), value: noteTint)
                .fixedSize()
                .accessibilityHidden(true)
            Text(drop.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
            if !drop.artist.isEmpty {
                Text(verbatim: "·")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
                    .accessibilityHidden(true)
                Text(drop.artist)
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

/// 耳朵里的一张图,按对象身份比较(同一张封面的两次解码是两个对象,是不是同一张画面另由指纹判)。
struct NotchArtworkRef: Equatable {
    let image: NSImage

    static func == (lhs: NotchArtworkRef, rhs: NotchArtworkRef) -> Bool { lhs.image === rhs.image }
}

/// 两张封面是不是同一张画面(`ArtworkFingerprint`)。指纹按图对象缓存最近几张:每次换歌最多算两三张,
/// 每张要把整张图解一遍再缩到 8×8。
@MainActor
enum NotchArtworkFingerprints {
    private static var cache: [(image: NSImage, print: ArtworkFingerprint?)] = []

    static func same(_ lhs: NotchArtworkRef, _ rhs: NotchArtworkRef) -> Bool {
        guard let a = fingerprint(lhs.image), let b = fingerprint(rhs.image) else { return false }
        return a.isSamePicture(as: b)
    }

    private static func fingerprint(_ image: NSImage) -> ArtworkFingerprint? {
        if let hit = cache.first(where: { $0.image === image }) { return hit.print }
        let made = image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { ArtworkFingerprint(image: $0) }
        cache.insert((image, made), at: 0)
        if cache.count > 4 { cache.removeLast(cache.count - 4) }
        return made
    }
}

/// 换歌翻牌:耳朵里那枚封面(只在开关开着时用,关着走原来那一格)。左耳这一枚连广告时的喇叭一起画,
/// 广告结束、新封面到了,喇叭才能翻成封面。什么时候翻、什么时候原地换、什么时候先留着原来那一面,
/// 规则都在 Core `NotchArtworkFlipPlanner`;这里只执行。
///
/// 翻的是封面本身(以它自己的中心为轴),外面那层占满耳朵的 frame 不跟着转。
struct NotchEarArtworkFlip<Artwork: View, AdIcon: View>: View {
    typealias Planner = NotchArtworkFlipPlanner<NotchArtworkRef>

    private let trackKey: String
    private let artworkImage: NSImage?
    private let highResImage: NSImage?
    private let overrideImage: NSImage?
    private let isAdBreak: Bool
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

    /// - Parameters:
    ///   - overrideImage: 盖过封面的那张(电台口白时的台标)。
    ///   - isAdBreak: 这一格此刻该画喇叭(只有左耳传 true)。
    init(trackKey: String, artworkImage: NSImage?, highResImage: NSImage?, overrideImage: NSImage?,
         isAdBreak: Bool, alignment: Alignment, animated: Bool,
         @ViewBuilder artwork: @escaping (NSImage) -> Artwork,
         @ViewBuilder adIcon: @escaping () -> AdIcon) {
        self.trackKey = trackKey
        self.artworkImage = artworkImage
        self.highResImage = highResImage
        self.overrideImage = overrideImage
        self.isAdBreak = isAdBreak
        self.alignment = alignment
        self.animated = animated
        self.artwork = artwork
        self.adIcon = adIcon
        let target = Self.target(isAdBreak: isAdBreak, image: overrideImage ?? highResImage ?? artworkImage)
        _planner = State(initialValue: Planner(shown: target))
        _front = State(initialValue: target)
        _previousImages = State(initialValue: [artworkImage, highResImage, overrideImage].compactMap { $0 })
    }

    private struct Input: Equatable {
        let key: String
        let isAdBreak: Bool
        let artwork: ObjectIdentifier?
        let highRes: ObjectIdentifier?
        let override: ObjectIdentifier?
    }

    private enum FaceID: Hashable {
        case empty, adIcon, artwork(ObjectIdentifier)
    }

    private var input: Input {
        Input(key: trackKey, isAdBreak: isAdBreak, artwork: artworkImage.map(ObjectIdentifier.init),
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
            react(trackChanged: old.key != new.key)
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

    private func react(trackChanged: Bool) {
        let now = Date()
        if trackChanged {
            planner.trackChanged(staleArtwork: previousImages.map { NotchArtworkRef(image: $0) }, now: now)
        }
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

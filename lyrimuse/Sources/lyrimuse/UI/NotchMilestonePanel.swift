import LyrimuseCore
import SwiftUI

/// 收听里程碑的报喜面板:左边大号数字(出现时扫一道光),右边两行字。挂在灵动岛顶行下面(`NotchLyricsView`),
/// 高度是 `NotchMetrics.milestonePanelHeight`。
struct NotchMilestonePanel: View {
    let milestone: ListenMilestone
    let tint: Color
    /// false = 「减弱动态效果」开着:不扫光。
    let animated: Bool
    @State private var shine = false

    private var number: String { milestone.count.formatted(.number) }

    private var title: String {
        switch milestone.kind {
        case .track: return String(format: L10n.t("第 %@ 次收听"), number)
        case .total: return String(format: L10n.t("累计第 %@ 次收听"), number)
        }
    }

    private var subtitle: String {
        let title = TrackNameDisplay.cleaned(milestone.title)
        let artist = TrackNameDisplay.cleaned(milestone.artist)
        return artist.isEmpty ? title : "\(title) · \(artist)"
    }

    var body: some View {
        HStack(spacing: 14) {
            numberText
                .overlay {
                    if animated { shineOverlay }
                }
                .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .truncationMode(.tail)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.1).delay(0.35)) { shine = true }
        }
    }

    private var numberText: some View {
        Text(number)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
    }

    /// 一道白光从左扫到右,只扫一次。
    private var shineOverlay: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.5)
                .offset(x: shine ? geo.size.width : -geo.size.width * 0.5)
        }
        .mask(numberText)
        .allowsHitTesting(false)
    }
}

/// 报喜时从卡片下沿落下的一把碎屑。挂在卡片裁剪的外面(`NotchWindowRoot`),落进窗口下方那片透明区;
/// 不吃点击、读屏不念,「减弱动态效果」开着时不落。
struct NotchMilestoneConfetti: View {
    let milestone: ListenMilestone?
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pieces: [Piece] = []
    @State private var falling = false
    @State private var generation = 0

    struct Piece: Identifiable {
        let id: Int
        let x: CGFloat
        let dx: CGFloat
        let dy: CGFloat
        let rotation: Double
        let size: CGFloat
        let color: Color
        let delay: Double
    }

    /// 报喜那一拍卡片才开始往报喜高度长(展开弹簧,response 0.38),碎屑按终态卡高摆:先等卡片长到位再落,
    /// 不然头一两百毫秒碎屑悬在卡片外面。
    static let startDelay: Double = 0.3

    private static let colors: [Color] = [
        Color(red: 0.93, green: 0.82, blue: 0.56),
        Color(red: 1.0, green: 0.95, blue: 0.81),
        Color(red: 0.85, green: 0.66, blue: 0.35),
        Color(red: 0.96, green: 0.89, blue: 0.69),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(piece.color)
                    .frame(width: piece.size, height: piece.size * 0.6)
                    .rotationEffect(.degrees(falling ? piece.rotation : 0))
                    .offset(x: piece.x + (falling ? piece.dx : 0), y: cardHeight - 4 + (falling ? piece.dy : 0))
                    .opacity(falling ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).delay(piece.delay), value: falling)
            }
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: milestone) { _, next in
            guard next != nil, !reduceMotion else { return }
            generation += 1
            let round = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.startDelay) {
                if generation == round { fire(round: round) }
            }
        }
    }

    private func fire(round: Int) {
        falling = false
        let span = max(1, cardWidth - 60)
        pieces = (0..<18).map { i in
            let x = 30 + CGFloat.random(in: 0...span)
            let size = CGFloat.random(in: 4...6)
            // 横向落点不出卡片:窗口跟展开卡一样宽,出去的那截会被窗口边界切掉。
            return Piece(id: round * 100 + i,
                  x: x,
                  dx: .random(in: max(-60, -x)...min(60, max(0, cardWidth - size - x))),
                  dy: .random(in: NotchMetrics.milestoneConfettiDrop),
                  rotation: .random(in: -270...270),
                  size: size,
                  color: Self.colors[i % Self.colors.count],
                  delay: .random(in: 0...0.25))
        }
        DispatchQueue.main.async { falling = true }
        // 一轮落完就清掉,别把十几个透明视图一直挂着。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            if generation == round { pieces = [] }
        }
    }
}

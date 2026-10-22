import AppKit
import LyrimuseCore
import SwiftUI
import UniformTypeIdentifiers

// 「分享歌词」独立窗口(`Window(id: "lyrics-share")`,见 App.swift):歌词窗口「⋯ › 分享歌词…」和深链 `lyrics-share` 开它。
// 左边勾 1～4 句(`LyricShareCard`),右边是卡片预览,底下三个开关(译文 / 读音 / Lyrimuse 标识)和拷贝、保存、分享。
// 打开时按正在放的那首取一份快照,开着期间不跟着换歌;再点一次「分享歌词…」重取(`AppActions.lyricShareRefreshRequests`)。
// 卡片背景是歌词窗口那套封面图层画成的一帧(`WindowBackgroundLayers.stillImage`),出图 1080×1350。见 07 章决策 180。
struct LyricShareWindow: View {
    @State private var snapshot: Snapshot?
    @State private var selection: [String] = []
    @State private var showsTranslation = true
    @State private var showsRomanization = false
    @State private var showsBrand = true
    @State private var feedback: String?
    @ObservedObject private var languageSettings = AppLanguageObserver.shared

    struct Snapshot {
        let title: String
        let artist: String
        let artwork: NSImage?
        let background: NSImage?
        let lines: [LyricShareCard.Line]
    }

    var body: some View {
        Group {
            if let snapshot, !snapshot.lines.isEmpty {
                content(snapshot)
            } else {
                ContentUnavailableView(
                    snapshot == nil || snapshot?.title.isEmpty == true ? L10n.t("当前无正在播放的歌曲") : L10n.t("当前无歌词"),
                    systemImage: "music.note")
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle(L10n.t("分享歌词"))
        .task { load() }
        .onReceive(AppActions.shared.lyricShareRefreshRequests) { load() }
    }

    private func content(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 0) {
            lineList(snapshot)
                .frame(width: 300)
            Divider()
            VStack(spacing: 16) {
                LyricShareCardView(card: card(snapshot))
                    .frame(width: LyricShareCardView.size.width, height: LyricShareCardView.size.height)
                    .scaleEffect(0.62)
                    .frame(width: LyricShareCardView.size.width * 0.62, height: LyricShareCardView.size.height * 0.62)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                HStack(spacing: 14) {
                    Toggle(L10n.t("译文"), isOn: $showsTranslation)
                        .disabled(!snapshot.lines.contains { $0.translation != nil })
                    Toggle(L10n.t("读音"), isOn: $showsRomanization)
                        .disabled(!snapshot.lines.contains { $0.romanization != nil })
                    Toggle(L10n.t("Lyrimuse 标识"), isOn: $showsBrand)
                }
                .toggleStyle(.checkbox)
                HStack(spacing: 10) {
                    Button(L10n.t("拷贝图片")) { copy(snapshot) }
                    Button(L10n.t("保存图片…")) { save(snapshot) }
                    if let image = render(snapshot) {
                        ShareLink(item: Image(nsImage: image),
                                  preview: SharePreview(snapshot.title, image: Image(nsImage: image))) {
                            Text(L10n.t("分享…"))
                        }
                    }
                }
                .settingsGlassButtons()
                .disabled(selection.isEmpty)
                Text(feedback ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private func lineList(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: L10n.t("选择 1～%d 句"), LyricShareCard.maxLines))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.lines) { line in
                            lineRow(line, order: snapshot.lines.map(\.id))
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    if let first = selection.first { proxy.scrollTo(first, anchor: .center) }
                }
            }
        }
    }

    private func lineRow(_ line: LyricShareCard.Line, order: [String]) -> some View {
        let on = selection.contains(line.id)
        let full = !on && selection.count >= LyricShareCard.maxLines
        return Button {
            selection = LyricShareCard.toggled(selection, line.id, order: order)
            feedback = nil
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text)
                        .font(.system(size: 13))
                    if let tr = line.translation {
                        Text(tr).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .opacity(full ? 0.45 : 1)
    }

    private func card(_ snapshot: Snapshot) -> LyricShareCardView.Card {
        let picked = snapshot.lines.filter { selection.contains($0.id) }
        return LyricShareCardView.Card(
            title: snapshot.title, artist: snapshot.artist, artwork: snapshot.artwork, background: snapshot.background,
            lines: picked, showsTranslation: showsTranslation, showsRomanization: showsRomanization,
            showsBrand: showsBrand)
    }

    @MainActor private func render(_ snapshot: Snapshot) -> NSImage? {
        guard !selection.isEmpty else { return nil }
        let renderer = ImageRenderer(content: LyricShareCardView(card: card(snapshot))
            .frame(width: LyricShareCardView.size.width, height: LyricShareCardView.size.height))
        renderer.scale = LyricShareCard.pixelSize.width / LyricShareCardView.size.width
        return renderer.nsImage
    }

    @MainActor private func copy(_ snapshot: Snapshot) {
        guard let image = render(snapshot) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        feedback = L10n.t("已拷贝")
    }

    @MainActor private func save(_ snapshot: Snapshot) {
        guard let image = render(snapshot), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = LyricShareCard.fileName(title: snapshot.title, artist: snapshot.artist)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
            feedback = L10n.t("已保存")
        } catch {
            feedback = L10n.t("保存失败，请重试")
        }
    }

    /// 按正在放的那首取快照。开关初值跟歌词窗口当前显不显示译文、读音走;标识默认开。
    @MainActor private func load() {
        let playback = PlaybackCoordinator.shared
        let lines = LyricShareCard.lines(from: playback.allLines)
        let artwork = playback.highResArtworkImage ?? playback.artworkImage
        let background = playback.windowBackgroundLayers?.stillImage(size: LyricShareCardView.size)
            ?? artwork.flatMap { LyricShareCardView.blurredBackground($0, size: LyricShareCardView.size) }
        snapshot = Snapshot(title: playback.displayTitle, artist: playback.displayArtist, artwork: artwork,
                            background: background, lines: lines)
        selection = LyricShareCard.initialSelection(
            lines: lines, allLineIDs: playback.allLines.map(\.id), currentIndex: playback.currentLineIndex)
        let settings = AppSettings.shared
        showsTranslation = settings.showTranslation && lines.contains { $0.translation != nil }
        showsRomanization = settings.showRomanization && lines.contains { $0.romanization != nil }
        showsBrand = true
        feedback = nil
    }
}

/// 分享卡片本体:4:5,封面和歌名歌手在上,选中的几句在中间,标识在右下。按点排版、出图时放大到 1080 宽。
struct LyricShareCardView: View {
    static let size = CGSize(width: 540, height: 675)

    struct Card {
        let title: String
        let artist: String
        let artwork: NSImage?
        let background: NSImage?
        let lines: [LyricShareCard.Line]
        let showsTranslation: Bool
        let showsRomanization: Bool
        let showsBrand: Bool
    }

    let card: Card

    var body: some View {
        ZStack {
            backgroundLayer
            Color.black.opacity(0.12)
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 24)
                ViewThatFits(in: .vertical) {
                    ForEach([31.0, 27.0, 23.0, 20.0], id: \.self) { size in
                        lyricBlock(fontSize: size)
                    }
                }
                Spacer(minLength: 24)
                brand
            }
            .padding(48)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var backgroundLayer: some View {
        if let background = card.background {
            Image(nsImage: background).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            if let artwork = card.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 15, y: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                Text(card.artist)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .lineLimit(2)
        }
    }

    private func lyricBlock(fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: fontSize * 0.85) {
            ForEach(card.lines) { line in
                VStack(alignment: .leading, spacing: fontSize * 0.2) {
                    Text(line.text)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(.white)
                    if card.showsRomanization, let roma = line.romanization {
                        Text(roma)
                            .font(.system(size: fontSize * 0.5))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    if card.showsTranslation, let tr = line.translation {
                        Text(tr)
                            .font(.system(size: fontSize * 0.55))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var brand: some View {
        HStack(spacing: 6) {
            Spacer()
            if card.showsBrand {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .opacity(0.85)
                Text("Lyrimuse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(height: 22)
    }

    /// 没有烘焙好的背景图层时(歌词窗口没开过、背景不是封面那一档)用封面直接模糊压暗。
    static func blurredBackground(_ artwork: NSImage, size: CGSize) -> NSImage? {
        guard let tiff = artwork.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let scale = max(size.width / ci.extent.width, size.height / ci.extent.height) * 1.3
        let blurred = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).clampedToExtent()
            .applyingGaussianBlur(sigma: 45)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputBrightnessKey: -0.08])
        let crop = CGRect(x: (ci.extent.width * scale - size.width) / 2, y: (ci.extent.height * scale - size.height) / 2,
                          width: size.width, height: size.height)
        guard let cg = CIContext().createCGImage(blurred, from: crop) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
}

extension WindowBackgroundLayers {
    /// 歌词窗口背景按初始姿态画成静止的一帧(几何同 `BackdropNSView.layout`:暗底铺满,光斑绕锚点转到起始角、
    /// 放大 scale 倍,以 lighten 混合、不透明度 0.25),再压一层同窗口的 0.15 黑。
    func stillImage(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            Self.drawAspectFill(self.base, in: rect, context: ctx)
            for (i, pose) in self.poses.enumerated() where i < self.glows.count {
                ctx.saveGState()
                let anchor = CGPoint(x: rect.width * pose.anchor.x, y: rect.height * (1 - pose.anchor.y))
                ctx.translateBy(x: anchor.x, y: anchor.y)
                ctx.rotate(by: CGFloat(-(pose.initialAngle - 12) * .pi / 180))
                ctx.translateBy(x: -anchor.x, y: -anchor.y)
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.scaleBy(x: pose.scale, y: pose.scale)
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
                ctx.setBlendMode(.lighten)
                ctx.setAlpha(0.25)
                Self.drawAspectFill(self.glows[i], in: rect, context: ctx)
                ctx.restoreGState()
            }
            ctx.setFillColor(NSColor(white: 0, alpha: 0.15).cgColor)
            ctx.fill(rect)
            return true
        }
    }

    private static func drawAspectFill(_ image: NSImage, in rect: CGRect, context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = max(rect.width / CGFloat(cg.width), rect.height / CGFloat(cg.height))
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        context.draw(cg, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }
}

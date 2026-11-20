import AppKit
import CoreGraphics
import Foundation
import LyrimuseCore

/// 灵动岛左右耳各自的宽度(「两耳等宽」开关):两耳等宽时新算法跟原公式逐数值一致的守卫,两耳不等宽时的几何、命中、
/// 进度线、出场、无刘海屏,以及 App 侧接线契约。见 05 章决策 160。
func runNotchEarWidthTests() {
    typealias W = NotchEarWidths
    let metrics = NotchCardLayout.Metrics(cardPadding: 10, contentInset: 16, collapsedEarWidth: 34, milestonePanelHeight: 76,
                                          trackDropHeight: 26, progressLineStrip: 4)
    func layout(notch: CGFloat = 179, steady: CGFloat, expanded: CGFloat, offset: CGFloat = 0,
                collapsed: Bool = false, isExpanded: Bool = false, topRowLyrics: CGFloat = 0) -> NotchCardLayout {
        NotchCardLayout(
            metrics: metrics, isCollapsed: collapsed, isExpanded: isExpanded, notchWidth: notch, contentTopInset: 32,
            steadyCardWidth: steady, expandedCardWidth: expanded, lyricRowHeight: 44, expandedLyricListHeight: 0,
            hasTrack: true, isAdBreak: false, hasMilestone: false, hasTrackDrop: false, transientBannerActive: false,
            showsProgressLine: false, progressLineStyle: .bottom, showsLyrics: false, trackHasLyricPreview: true,
            trackHasScrubber: true, expandedShowsNextLine: true, expandedShowsControls: true, trackInfoShowsArtwork: false,
            trackInfoShowsTitle: false, trackInfoShowsArtist: false, trackInfoShowsAlbum: false, expandedShowsQuickActions: false,
            topRowLyricsWidth: topRowLyrics, steadyOffset: offset)
    }

    // MARK: 两耳等宽:跟原公式逐数值一致

    // 原公式照抄一份当参照:收起宽 min(稳态, 空当 + 2 × 收起耳宽 + 2 × 内边距),耳宽 (卡宽 − 空当 − 2 × 内边距) / 2,
    // 刘海在卡片正中,横扫判据按同一个中心,出场裁剪以卡片中心为锚。
    var linkedMismatches: [String] = []
    for notch in [0, 179, 179.25, 186.5] as [CGFloat] {
        for steady in stride(from: 200 as CGFloat, through: 800, by: 7.25) {
            for expanded in [steady, steady + 106.5, 800] {
                let gap = notch > 0 ? notch : NotchCardLayout.collapsedGapWithoutNotch
                let oldCollapsed = min(steady, gap + 2 * 34 + 2 * 10)
                for (collapsed, isExpanded) in [(false, false), (true, false), (false, true)] {
                    let l = layout(notch: notch, steady: steady, expanded: expanded, collapsed: collapsed, isExpanded: isExpanded)
                    let oldWidth = collapsed ? oldCollapsed : (isExpanded ? expanded : steady)
                    if l.cardWidth != oldWidth || l.cardOffset != 0 { linkedMismatches.append("width \(notch)/\(steady)") }
                    let ears = l.earWidths(cardWidth: l.cardWidth, offset: l.cardOffset)
                    let oldEar = max(0, (l.cardWidth - notch - l.topRowPadding * 2) / 2)
                    if ears.left != oldEar || ears.right != oldEar { linkedMismatches.append("ears \(notch)/\(steady)") }
                }
                if W.expandedWidth(steady: .symmetric(cardWidth: steady, notchWidth: notch), notchWidth: notch,
                                   expandedSetting: expanded) != NotchWidthBounds.expandedWidth(steady: steady, expandedSetting: expanded) {
                    linkedMismatches.append("expanded \(notch)/\(steady)")
                }
                let hit = NotchHoverHit.Notch(width: notch, bottom: 32)
                let oldLeft = (steady - notch) / 2
                if hit.span(cardWidth: steady) != oldLeft...(oldLeft + notch) { linkedMismatches.append("span \(steady)") }
                for x in [-20, 0, steady / 2, steady + 9] as [CGFloat] {
                    for rightward in [true, false] {
                        let old = rightward ? x > expanded / 2 + steady / 2 + 8 : x < expanded / 2 - steady / 2 - 8
                        if NotchHoverHit.sweptPastSteadyCard(rightward: rightward, x: x, cardWidth: expanded, steadyWidth: steady)
                            != old { linkedMismatches.append("sweep \(steady)/\(x)") }
                    }
                }
                for fraction in [0.12, 0.4, 1] as [CGFloat] {
                    let span = NotchReveal.visibleSpan(cardWidth: steady, widthFraction: fraction,
                                                       startFraction: notch / steady, notchOffset: 0)
                    if span.minX != steady / 2 - steady * fraction / 2 { linkedMismatches.append("reveal \(steady)") }
                }
                let path = NotchEarProgressPath(width: steady, height: 32, notchWidth: notch, notchHeight: 32, shoulder: 4,
                                                cardCornerRadius: 8, inset: 1.25)
                let centered = NotchEarProgressPath(width: steady, height: 32, notchWidth: notch, notchHeight: 32, shoulder: 4,
                                                    cardCornerRadius: 8, inset: 1.25, notchCenterX: steady / 2)
                if path != centered { linkedMismatches.append("progress \(steady)") }
            }
        }
    }
    expectEqual(linkedMismatches, [],
                "两耳等宽(守卫): 偏移 0 时卡片宽、收起宽、耳宽、展开宽、刘海位置、横扫判据、出场裁剪、进度线跟原公式逐数值一致")

    // MARK: 两耳不等宽:每侧按设定值(刘海 179)

    let floors = NotchEarSpan(left: 16, right: 16)
    let steadySpan = W.steady(setting: NotchEarSpan(left: 200, right: 41.5), floor: floors)
    expectEqual([steadySpan.left, steadySpan.right], [200, 41.5], "两耳不等宽: 每侧照自己的设定值画")
    expectEqual(W.steady(setting: NotchEarSpan(left: 188, right: 400), floor: floors), NotchEarSpan(left: 188, right: 400),
                "两耳不等宽: 设定再宽也照设定,不按菜单栏两侧空位收窄")
    expectEqual(W.steady(setting: NotchEarSpan(left: 200, right: 30), floor: NotchEarSpan(left: 16, right: 58)).right, 58,
                "两耳不等宽: 设定比这一侧的模块下限还窄时抬到下限,下限只看这一侧")
    expectEqual(W.steady(setting: NotchEarSpan(left: 10, right: 10), floor: NotchEarSpan(left: 38, right: 16)),
                NotchEarSpan(left: 38, right: 16), "两耳不等宽: 每只耳朵的下限各算各的,不取较大者")
    let cardWidth = steadySpan.cardWidth(notchWidth: 179)
    expectEqual([cardWidth, steadySpan.offset], [420.5, -79.25], "两耳不等宽: 卡片 = 刘海 + 两侧,中心往左偏 79.25")
    let expanded = W.expandedWidth(steady: steadySpan, notchWidth: 179, expandedSetting: 468)
    expectEqual(expanded, 579, "两耳不等宽: 展开以刘海为中心、宽 = max(展开设定 468, 刘海 + 2 × 较宽一侧 200) = 579")
    expectEqual(W.expandedWidth(steady: steadySpan, notchWidth: 179, expandedSetting: 700), 700, "两耳不等宽: 展开设定更宽时照设定")
    let expandedLeft = (expanded - 179) / 2
    expectEqual(expandedLeft >= steadySpan.left && expandedLeft >= steadySpan.right, true, "两耳不等宽: 展开卡片两侧都包住稳态卡片")

    let steadyLayout = layout(steady: cardWidth, expanded: expanded, offset: steadySpan.offset)
    let collapsedLayout = layout(steady: cardWidth, expanded: expanded, offset: steadySpan.offset, collapsed: true)
    let expandedLayout = layout(steady: cardWidth, expanded: expanded, offset: steadySpan.offset, isExpanded: true)
    expectEqual([steadyLayout.cardWidth, steadyLayout.cardOffset], [420.5, -79.25], "两耳不等宽: 稳态偏心")
    expectEqual([collapsedLayout.cardWidth, collapsedLayout.cardOffset], [264.5, -1.25],
                "两耳不等宽: 收起每侧 min(稳态外露宽, 44):左 44、右 41.5")
    expectEqual([expandedLayout.cardWidth, expandedLayout.cardOffset], [579, 0], "两耳不等宽: 展开以刘海为中心")
    let ears = steadyLayout.earWidths(cardWidth: 420.5, offset: -79.25)
    expectEqual([ears.left, ears.right], [190, 31.5], "两耳不等宽: 左耳 = 外露宽 200 − 内边距、右耳 41.5 − 内边距")
    expectEqual([ears.left - 6, ears.right - 6], [184, 25.5], "两耳不等宽: 歌词槽 = 外露宽 − 16(示意图里左当前句槽 184)")
    expectEqual(steadySpan, NotchEarSpan.of(cardWidth: 420.5, offset: -79.25, notchWidth: 179), "两耳不等宽: 宽和偏移换回两侧")
    expectEqual(W.collapsed(NotchEarSpan(left: 30, right: 200), notchWidth: 0, collapsedEarWidth: 34, cardPadding: 10),
                NotchEarSpan(left: 30, right: 134), "两耳不等宽(无刘海屏): 收起仍按 180 空当,每侧从中线量最多 90 + 44")

    // 关等宽起点与再开等宽:起点是此刻对称卡片两侧的外露宽,换回卡片宽一字不差。
    let start = W.unlinkStart(steadyCardWidth: 256, notchWidth: 179)
    expectEqual([start.left, start.right, start.cardWidth(notchWidth: 179), start.offset], [38.5, 38.5, 256, 0],
                "关掉两耳等宽: 两侧起点 = 当时对称的外露宽,卡片不跳")
    expectEqual(W.unlinkStart(steadyCardWidth: 360, notchWidth: 0), NotchEarSpan(left: 180, right: 180),
                "关掉两耳等宽(无刘海屏): 从中线往两侧量")
    expectEqual([W.resolvedSetting(0, fallback: 38.5), W.resolvedSetting(120, fallback: 38.5)], [38.5, 120],
                "两耳不等宽: 没设过的一侧按对称外露宽起步")
    expectEqual([W.usableRange(floor: 16).lowerBound, W.usableRange(floor: 57.5).lowerBound, W.usableRange(floor: 999).lowerBound],
                [16, 58, 398], "两耳不等宽: 每只耳朵滑杆下界 = 这一侧下限向上取整到步长,不越过上界")

    // MARK: 命中、横扫、进度线、出场跟着偏移

    let hit = NotchHoverHit.Notch(width: 179, bottom: 32, offset: -79.25)
    expectEqual(hit.span(cardWidth: 420.5), 200...379, "两耳不等宽: 刘海在卡片里从左外露宽 200 处开始")
    expectEqual([NotchHoverHit.region(point: CGPoint(x: 210, y: 34), cardWidth: 420.5, cardHeight: 32, passThroughBelow: nil,
                                      notch: hit),
                 NotchHoverHit.region(point: CGPoint(x: 190, y: 34), cardWidth: 420.5, cardHeight: 32, passThroughBelow: nil,
                                      notch: hit)],
                [.card, .outside], "两耳不等宽: 刘海正下方那一条跟着刘海走,卡片正中下方(刘海外)不算")
    expectEqual([NotchHoverHit.crossesNotch(from: CGPoint(x: 195, y: 10), to: CGPoint(x: 385, y: 10), cardWidth: 420.5, notch: hit),
                 NotchHoverHit.crossesNotch(from: CGPoint(x: 160, y: 10), to: CGPoint(x: 260, y: 10), cardWidth: 420.5, notch: hit)],
                [true, false], "两耳不等宽: 过刘海判据按偏心后的刘海位置")
    // 展开卡 579 以刘海为中心,稳态卡片 420.5 往左偏 79.25:在展开卡里稳态卡片占 [0, 420.5]。
    expectEqual([NotchHoverHit.sweptPastSteadyCard(rightward: true, x: 430, cardWidth: 579, steadyWidth: 420.5, offset: 0,
                                                  steadyOffset: -79.25),
                 NotchHoverHit.sweptPastSteadyCard(rightward: true, x: 425, cardWidth: 579, steadyWidth: 420.5, offset: 0,
                                                  steadyOffset: -79.25),
                 NotchHoverHit.sweptPastSteadyCard(rightward: false, x: -9, cardWidth: 579, steadyWidth: 420.5, offset: 0,
                                                  steadyOffset: -79.25),
                 NotchHoverHit.sweptPastSteadyCard(rightward: false, x: 1, cardWidth: 579, steadyWidth: 420.5, offset: 0,
                                                  steadyOffset: -79.25)],
                [true, false, true, false], "两耳不等宽: 横扫判据按稳态卡片偏心后的两条外沿")
    let leftHalf = NotchEarProgressPath(width: 420.5, height: 32, notchWidth: 179, notchHeight: 32, shoulder: 4,
                                        cardCornerRadius: 8, inset: 1.25, notchCenterX: 420.5 / 2 + 79.25)
    let rightHalf = NotchEarProgressPath(width: 420.5, height: 32, notchWidth: 179, notchHeight: 32, shoulder: 4,
                                         cardCornerRadius: 8, inset: 1.25, notchCenterX: 420.5 / 2 - 79.25)
    expectEqual([leftHalf.endX, rightHalf.endX], [200, 41.5], "两耳不等宽: 进度线两半各自停在刘海左右沿(右半在镜像坐标里)")
    let revealed = NotchEarProgressPath(width: 420.5, height: 76, notchWidth: 179, notchHeight: 32, shoulder: 4,
                                        cardCornerRadius: 8, inset: 1.25, notchCenterX: 289.5)
    expectEqual(revealed.endX, 289.5, "两耳不等宽: 底边露出刘海时两半在刘海中心下面接上")
    let startFraction = NotchReveal.startWidthFraction(notchWidth: 179, cardWidth: 420.5)
    let revealStart = NotchReveal.visibleSpan(cardWidth: 420.5, widthFraction: startFraction, startFraction: startFraction,
                                              notchOffset: -79.25)
    let revealMid = NotchReveal.visibleSpan(cardWidth: 420.5, widthFraction: (1 + startFraction) / 2,
                                            startFraction: startFraction, notchOffset: -79.25)
    let revealEnd = NotchReveal.visibleSpan(cardWidth: 420.5, widthFraction: 1, startFraction: startFraction, notchOffset: -79.25)
    func rounded(_ values: [CGFloat]) -> [CGFloat] { values.map { ($0 * 1000).rounded() / 1000 } }
    expectEqual(rounded([revealStart.minX, revealStart.width, revealMid.minX, revealMid.minX + revealMid.width,
                         revealEnd.minX, revealEnd.width]),
                [200, 179, 100, 399.75, 0, 420.5],
                "两耳不等宽: 出场从刘海那一段撑开,两条外沿按同一进度各自走到卡片两侧")

    // MARK: 无刘海屏的顶行歌词

    let topRow = NotchTopRowLyrics.fit(span: NotchEarSpan(left: 300, right: 40), earWidth: 28, cardPadding: 10)
    expectEqual([topRow.span.left, topRow.span.right, topRow.lyricWidth], [300, 68, 292],
                "两耳不等宽(无刘海屏): 中线当宽 0 的刘海,每侧至少放得下一只耳朵和半段最窄歌词,歌词是两耳之间剩下的")
    let wideTopRow = NotchTopRowLyrics.fit(span: NotchEarSpan(left: 400, right: 380), earWidth: 28, cardPadding: 10)
    expectEqual([wideTopRow.span.left, wideTopRow.span.right], [400, 380], "两耳不等宽(无刘海屏): 两侧照设定,不按菜单栏收窄")
    let topRowLayout = layout(notch: 0, steady: 330, expanded: 482, offset: -110, topRowLyrics: 254)
    let topRowEars = topRowLayout.earWidths(cardWidth: 330, offset: -110)
    expectEqual([topRowEars.left, topRowEars.right], [28, 28], "两耳不等宽(无刘海屏): 画顶行歌词时两只耳朵等宽,歌词在卡片正中")

    // MARK: 深链往返

    func link(_ string: String) -> LyrimuseDeepLink? {
        URL(string: string).flatMap { LyrimuseDeepLink(url: $0, scheme: "lyrimuse") }
    }
    expectEqual(link("lyrimuse://debug/notch-behavior?ear-widths=split&left-width=200&right-width=120"),
                .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, earWidthsLinked: false,
                                      leftEarWidth: 200, rightEarWidth: 120)),
                "两耳不等宽(深链): ear-widths=split + 两侧宽度")
    expectEqual([link("lyrimuse://debug/notch-behavior?ear-widths=Linked"), link("lyrimuse://debug/notch-behavior?ear-widths=half"),
                 link("lyrimuse://debug/notch-behavior?left-width=0")],
                [.debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, earWidthsLinked: true)), nil, nil],
                "两耳不等宽(深链): linked 不分大小写,认不出的档和 0 宽不认")
    for original in [LyrimuseDeepLink.debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, earWidthsLinked: false,
                                                           leftEarWidth: 200.5, rightEarWidth: 41)),
                     .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, earWidthsLinked: true)),
                     .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, rightEarWidth: 64))] {
        expectEqual(original.url(scheme: "lyrimuse").flatMap { LyrimuseDeepLink(url: $0, scheme: "lyrimuse") }, original,
                    "两耳不等宽(深链): 往返 \(original)")
    }

    // MARK: App 接线(契约)

    func app(_ path: String) -> String {
        (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/" + path), encoding: .utf8)) ?? ""
    }
    let controller = app("UI/NotchLyricsWindowController.swift"), root = app("UI/NotchWindowRoot.swift")
    let view = app("UI/NotchLyricsView.swift"), topRowView = app("UI/NotchLyricsView+TopRow.swift")
    let chrome = app("UI/NotchChromeSource.swift"), stage = app("UI/NotchEditorStage.swift")
    let settings = app("Settings/AppSettings.swift"), rows = app("UI/NotchSettingsRows.swift")
    let progress = app("UI/NotchProgressLine.swift"), reveal = app("UI/NotchRevealShape.swift")
    let recompute = sourceBody("private func recomputeGeometry(animate: Bool)", in: controller)
    expectEqual(sourceHas(recompute, "if !earWidthsLinked {")
                && sourceHas(recompute, "} else if placement == .topRow {")
                && sourceHas(recompute, "if steadyCardOffset != offset { steadyCardOffset = offset }")
                && sourceHas(recompute, "NotchEarWidths.expandedWidth(steady: $0, notchWidth: geo.notchWidth, expandedSetting: baseExpandedContentWidth)"),
                true, "两耳不等宽(契约): 真窗口两耳等宽时走原路径,分开时按两侧算稳态、偏移和以刘海为中心的展开宽")
    expectEqual(sourceHas(controller, "return NSRect(x: window.frame.midX - cardWidth / 2 + cardOffset,")
                && sourceHas(controller, "NotchHoverHit.Notch(width: notchWidth, bottom: contentTopInset, offset: cardOffset)")
                && sourceHas(controller, "\"leftEarWidth\": cardLayout.steadySpan.left, \"rightEarWidth\": cardLayout.steadySpan.right"),
                true, "两耳不等宽(契约): 卡片屏幕矩形、刘海命中跟着偏移,debug/state 报两侧宽度")
    expectEqual(sourceHas(controller, "AppSettings.shared.$notchEarWidthsLinked, AppSettings.shared.$notchLeftEarWidth, AppSettings.shared.$notchRightEarWidth")
                && sourceHas(controller, "earWidthsLinked = linked\nleftEarWidthSetting = left\nrightEarWidthSetting = right\nrecomputeGeometry(animate: false)"),
                true, "两耳不等宽(契约): 三个设置变了先写镜像再重算几何")
    expectEqual(sourceHas(root, ".modifier(NotchCardOffsetEffect(offset: controller.cardOffset))")
                && sourceHas(root, ".animation(cardAnimation, value: controller.cardOffset)")
                && sourceHas(root, "(cardWidth - notch.width) / 2 - notch.offset + point.x")
                && sourceHas(root, "offset: controller.cardOffset,\nsteadyOffset: controller.steadyCardOffset)")
                && sourceHas(root, "scaleEffect(controller.isVanished ? 0.001 : 1, anchor: vanishAnchor)")
                && sourceHas(root, "startWidthFraction: revealStartWidth"),
                true, "两耳不等宽(契约): 窗口根把偏移跟宽度挂同一条弹簧,接收区、横扫、退场锚点、出场起点都按刘海")
    expectEqual(sourceHas(view, "let ears = controller.earWidths(cardWidth: proxy.size.width, offset: cardOffset)")
                && sourceHas(view, "topRow(leftEarWidth: ears.left, rightEarWidth: ears.right)")
                && sourceHas(view, ".offset(x: -cardOffset)")
                && sourceHas(view, "notchOffset: controller.cardOffset)")
                && sourceHas(topRowView, "atMinimumWidth: controller.isEarAtMinimumWidth(side) && !controller.showsTopRowLyrics")
                && sourceHas(topRowView, ".frame(width: leftEarWidth)") && sourceHas(topRowView, ".frame(width: rightEarWidth)"),
                true, "两耳不等宽(契约): 顶行按动画中的偏移分左右耳、刘海胶囊跟着刘海、音浪居中按各自那只耳朵判")
    expectEqual(sourceHas(chrome, "topRowLyricsWidth: topRowLyricsWidth, steadyOffset: steadyCardOffset)")
                && sourceHas(chrome, "notchOffset: cardOffset)")
                && sourceHas(progress, "notchOffset: notchOffset, mirrored: mirrored)")
                && sourceHas(reveal, "notchOffset: outline.notchOffset, startWidthFraction: startWidthFraction)"),
                true, "两耳不等宽(契约): 卡片布局、外形、进度线、出场裁剪读同一个偏移")
    expectEqual(sourceHas(stage, ".modifier(NotchCardOffsetEffect(offset: chrome.cardOffset))")
                && sourceHas(stage, "if let split = splitSteady { return split.span.cardWidth(notchWidth: chrome.notchWidth) }")
                && sourceHas(stage, "(local.minX - cardWidth / 2 + chrome.cardOffset) * scale")
                && sourceHas(stage, "let ears = chrome.earWidths(cardWidth: width, offset: chrome.cardOffset)")
                && sourceHas(stage, "if let split = splitSteadyOnCurrentScreen() { return Double(split.span.cardWidth(notchWidth: split.notchWidth)) }"),
                true, "两耳不等宽(契约): 编辑台与读数跟真窗口同一个公式,卡片、热区、浮层锚点跟着偏移")
    let unlink = sourceBody("static func setEarWidthsLinked(_ linked: Bool)", in: stage)
    expectEqual(sourceHas(unlink, "commitEarWidths(left: Double(start.left), right: Double(start.right))\n}\nsettings.notchEarWidthsLinked = linked")
                && !sourceHas(unlink, "notchContentWidth ="),
                true, "两耳不等宽(契约): 关等宽先写两侧起点再翻开关,分开期间不写稳态宽")
    expectEqual(sourceHas(settings, "notchEarWidthsLinked = (defaults.object(forKey: Keys.notchEarWidthsLinked) as? Bool) ?? Self.defaultNotchEarWidthsLinked")
                && sourceHas(settings, "static let defaultNotchEarWidthsLinked = true"),
                true, "两耳等宽(契约): 默认开,没存过的旧配置不迁移")
    expectEqual(sourceHas(rows, "Toggle(\"\", isOn: Binding(\nget: { settings.notchEarWidthsLinked },\nset: { NotchEditorStage.setEarWidthsLinked($0) }))")
                && sourceHas(rows, "if !settings.notchEarWidthsLinked {\nCardDivider()\nwidthRow\n}"),
                true, "两耳不等宽(契约): 左右耳浮层有等宽开关,关掉后才出现宽度行")

    // MARK: 浮层里「标签 + 玻璃下拉」一行放得下(各界面语言)

    // 浮层宽 W 时,一行里 13pt 行名 + 12pt 下拉字能用的宽 = W − 154:卡片两侧各让 10、行内边距 2 × 14、图标列 20、
    // HStack 三处间距 3 × 12、Spacer 至少 12、下拉胶囊自身 38(内边距 2 × 12 + 间距 4 + 箭头 10)。
    // 超过就折行(W = 320 时界线 166,见 05 章决策 159)。
    let catalogData = (try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Localization/Localizable.xcstrings"))) ?? Data()
    let catalog = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
    func localized(_ key: String, _ pack: String) -> String {
        if pack == "zh-hans" { return key }
        let units = (catalog[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        let unit = units.first { $0.key.lowercased() == pack }?.value as? [String: Any]
        return (unit?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
    }
    func textWidth(_ text: String, _ size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width.rounded(.up)
    }
    func popoverWidth(_ signature: String) -> CGFloat {
        let body = sourceBody(signature, in: rows)
        guard let r = body.range(of: #"width: (\d+)"#, options: .regularExpression) else { return 0 }
        return CGFloat(Double(body[r].dropFirst("width: ".count)) ?? 0)
    }
    let earBudget = popoverWidth("struct NotchEarPopover: View") - 154
    let display = app("UI/NotchModuleDisplay.swift")
    let moduleNames = sourceBody("var displayName: String", in: sourceBody("extension NotchEarModule", in: display))
        .components(separatedBy: "L10n.t(\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
    let moduleCases = sourceBody("enum NotchEarModule: String, Codable, Hashable, CaseIterable", in: settings)
        .components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }.count
    expectEqual(earBudget == 166 && moduleNames.count == moduleCases && moduleNames.contains("当前句") && moduleNames.contains("下一句"), true,
                "左右耳浮层: 读到浮层宽 320、每个模块的名字(\(moduleNames.count) / \(moduleCases))")
    let earOverflow = UILanguage.packs.compactMap { pack -> String? in
        let need = textWidth(localized("显示内容", pack), 13) + moduleNames.map { textWidth(localized($0, pack), 12) }.max()!
        return need > earBudget ? "\(pack) \(Int(need))" : nil
    }
    expectEqual(earOverflow, [], "左右耳浮层: 「显示内容」选最长的模块时各语言都排一行(行名 + 下拉字 ≤ \(Int(earBudget)))")
    let screenBudget = popoverWidth("struct NotchScreenPopover: View") - 154 - 20
    let screenFixed = ["自动", "跟随当前窗口", "全部屏幕", "已断开的屏幕"].map { textWidth(localized($0, "en"), 12) }.max()!
    expectEqual(textWidth(localized("显示在", "en"), 13) + screenFixed <= screenBudget, true,
                "屏幕浮层: 英文「Show On」+ ⓘ + 最长的固定选项不截断")
    let screenTight = UILanguage.packs.filter { textWidth(localized("显示在", $0), 13) + 40 > screenBudget }
    expectEqual(screenTight, [], "屏幕浮层: 各语言「显示在」排一行后下拉还留得下 40pt 字")
    let screenRow = sourceBody("struct NotchScreenSettingsRows: View", in: rows)
    let design = app("Settings/SettingsDesignSystem.swift")
    expectEqual(sourceHas(screenRow, "titleKeepsLine: true") && sourceHas(screenRow, "truncatesTitle: true")
                && sourceHas(design, ".layoutPriority(titleKeepsLine ? 2 : 0)") && sourceHas(design, ".layoutPriority(titleKeepsLine ? 1 : 0)")
                && sourceHas(design, ".fixedSize(horizontal: !truncatesTitle, vertical: true)")
                && sourceHas(design, "height: compact ? 28 : 32,\ntruncatesTitle: truncatesTitle"),
                true, "屏幕浮层(契约): 「显示在」标题先排满一行,屏幕名放不下时下拉里截断")
}

import CoreGraphics
import Foundation

/// 副屏网页发回来的一次点按:`{"tap":[u,v]}`,画面上的相对位置(0…1,左上为原点)。见 19 章决策 4。
public enum WebLyricsTap {
    public static func parse(_ payload: Data) -> CGPoint? {
        guard payload.count <= 256,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let pair = object["tap"] as? [NSNumber], pair.count == 2 else { return nil }
        let u = pair[0].doubleValue, v = pair[1].doubleValue
        guard u.isFinite, v.isFinite, (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }

    /// 本机打开的副屏一律能点;别的设备要「允许局域网设备控制播放」开着。
    public static func permits(remoteIsLoopback: Bool, lanControlEnabled: Bool) -> Bool {
        remoteIsLoopback || lanControlEnabled
    }
}

/// 副屏左栏那排播放控制的位置,照 `LyricsWindowView.playbackControls`:随机贴左缘、循环贴右缘,
/// 上一首 / 播放 / 下一首成组居中;各档尺寸按封面边长算再夹值(同 `ctrl(_:_:_:)`)。坐标是左栏自己的,y 向下。
public struct WebLyricsControlsLayout: Equatable, Sendable {
    public enum Button: CaseIterable, Sendable { case shuffle, previous, playPause, next, repeatMode }

    /// 手指点得中的最小高度(点)。
    public static let minimumHitSize: CGFloat = 44
    /// 命中区横向最多比格子宽出去这么多(每边)。
    public static let hitReach: CGFloat = 22

    public let modeFontSize: CGFloat
    public let skipFontSize: CGFloat
    public let playFontSize: CGFloat
    /// 每颗键占的格子(字形在格子里居中)。
    public let cells: [Button: CGRect]

    /// `skipGlyphWidth` 是上 / 下一首字形按 `skipFontSize` 排出来的宽(App 量好传进来)。
    public init(width w: CGFloat, rowTop: CGFloat, rowHeight: CGFloat, skipGlyphWidth: CGFloat) {
        func ctrl(_ ratio: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, w * ratio)) }
        modeFontSize = ctrl(0.043, 11, 18)
        skipFontSize = ctrl(0.060, 13, 25)
        playFontSize = ctrl(0.079, 17, 33)
        let modeCell = modeFontSize + 8
        let playCell = ctrl(0.10, 22, 38)
        let spacing = ctrl(0.116, 18, 48)
        let group = skipGlyphWidth * 2 + playCell + spacing * 2
        var x = (w - group) / 2
        func cell(_ x: CGFloat, _ width: CGFloat) -> CGRect { CGRect(x: x, y: rowTop, width: width, height: rowHeight) }
        var cells: [Button: CGRect] = [:]
        cells[.shuffle] = cell(0, modeCell)
        cells[.repeatMode] = cell(w - modeCell, modeCell)
        cells[.previous] = cell(x, skipGlyphWidth)
        x += skipGlyphWidth + spacing
        cells[.playPause] = cell(x, playCell)
        x += playCell + spacing
        cells[.next] = cell(x, skipGlyphWidth)
        self.cells = cells
    }

    /// 点中的键:格子横向往两边各扩到跟邻键的一半间距、最多 `hitReach`,两键之间没有点不中的空档;
    /// 竖向扩到至少 `minimumHitSize` 高。
    public func button(at point: CGPoint) -> Button? {
        let ordered: [Button] = [.shuffle, .previous, .playPause, .next, .repeatMode]
        for (i, b) in ordered.enumerated() {
            guard let c = cells[b] else { continue }
            let left = i > 0 ? cells[ordered[i - 1]].map { max(0, (c.minX - $0.maxX) / 2) } ?? Self.hitReach : Self.hitReach
            let right = i < ordered.count - 1
                ? cells[ordered[i + 1]].map { max(0, ($0.minX - c.maxX) / 2) } ?? Self.hitReach : Self.hitReach
            let growY = max(0, (Self.minimumHitSize - c.height) / 2)
            let hit = CGRect(x: c.minX - min(left, Self.hitReach), y: c.minY - growY,
                             width: c.width + min(left, Self.hitReach) + min(right, Self.hitReach), height: c.height + growY * 2)
            if hit.contains(point) { return b }
        }
        return nil
    }
}

import Foundation
import LyrimuseCore

// 「选择播放器」网格的纯逻辑(`PlayerPickerLayout`):具体播放器摆哪几张卡。
// 设置页「播放器」卡和引导页「选择播放器」那一步共用这一份。
func runPlayerPickerTests() {
    let order: [PlaybackPlayer] = [.appleMusic, .spotify, .qqMusic, .netease, .kugou, .soda, .auto]

    // ---- 勾着自动识别:规则不变,勾着没装的照样摆出来(卡片随时能勾,得有地方取消) ----
    do {
        let tiles = PlayerPickerLayout.tiles(order: order,
                                             selected: [.auto, .qqMusic],
                                             installed: [.appleMusic, .spotify])
        expectEqual(tiles.main, [.appleMusic, .spotify, .qqMusic],
                    "播放器网格: 勾着自动识别时,勾着但没装的也留在主网格里")
        expectEqual(tiles.more, [.netease, .kugou, .soda], "播放器网格: 勾着自动识别时其余没装的照样进「更多」")
        expectEqual(tiles.main.contains(.auto), false, "播放器网格: 「自动识别」那张卡不在 tiles 里,由 PlayerPicker 单独排")
    }

    // ---- 装了的 + 勾着没装的;其余没装的进「更多」 ----
    do {
        let tiles = PlayerPickerLayout.tiles(order: order,
                                             selected: [.appleMusic, .kugou],
                                             installed: [.appleMusic, .spotify])
        expectEqual(tiles.main, [.appleMusic, .spotify, .kugou],
                    "播放器网格: 勾着但没装的留在主网格里,不然没处取消勾选")
        expectEqual(tiles.more, [.qqMusic, .netease, .soda], "播放器网格: 其余没装的进「更多」,保持顺序")
        let everything = Set(tiles.main + tiles.more)
        expectEqual(everything, Set(order.filter { $0 != .auto }), "播放器网格: 主网格 + 「更多」正好覆盖全部具体播放器")
        expectEqual(Set(tiles.main).isDisjoint(with: tiles.more), true, "播放器网格: 同一个播放器不会同时出现在两处")
    }

    // ---- 全装了:没有「更多」 ----
    do {
        let all = Set(order.filter { $0 != .auto })
        let tiles = PlayerPickerLayout.tiles(order: order, selected: [.spotify], installed: all)
        expectEqual(tiles.more, [], "播放器网格: 全装了就没有「更多」那一格")
        expectEqual(tiles.main.count, all.count, "播放器网格: 全装了就全摆出来")
    }
}

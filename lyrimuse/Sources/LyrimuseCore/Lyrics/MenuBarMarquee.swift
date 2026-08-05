import Foundation

// 菜单栏歌词的跑马灯取窗算法(2026-08-05 加,点子来自 FlowX/Kadxy/FlowX——它的菜单栏
// 歌词超宽时会横向滚动,而不是像我们原来那样直接截断成"前 N 个字…")。
//
// ⚠️ 为什么是"算出该显示哪一段文字"而不是"做一个滚动动画":MenuBarExtra 默认(.menu)
// 样式的 label 里挂不住 SwiftUI 的动画/生命周期修饰符——本会话早先实测坐实过 `.task`
// 挂在 MenuBarLabel 上从来不触发(详见当时排查系统翻译兜底那一轮的结论)。但 label 本身
// 确实会跟着它读的 @Published 值变化重新渲染(菜单栏歌词能跟着换句就是靠这个)。所以
// 这里反过来做:把"现在该露出哪一段"当成纯数据算出来、由模型层按节奏发布,label 只管
// 渲染一个普通字符串,完全不依赖任何视图侧的动画能力。
//
// 纯函数、无状态,selftest 直接覆盖。
public enum MenuBarMarquee {
    // step 是"第几拍"(由调用方按固定间隔递增,见 MenuBarMarqueeTicker),holdSteps 是
    // 首尾各停留几拍。返回这一拍应该显示的那一段文字。
    //
    // 一个完整周期:开头停 holdSteps 拍(让人先看清开头)→ 每拍右移一个字 → 末尾再停
    // holdSteps 拍 → 回到开头循环。实际使用中歌词往往几秒就换一句、走不完一整个周期,
    // 循环只是"万一这一句特别长又停留很久"时的兜底行为,不会卡在末尾不动。
    //
    // 按字符(Character)取窗而不是按字节/UTF-16 —— 中文/emoji 一个字符占多个码元,
    // 按码元切会把一个字切成两半变成乱码。
    public static func window(text: String, maxChars: Int, step: Int, holdSteps: Int) -> String {
        guard maxChars > 0 else { return "" }
        let chars = Array(text)
        // 装得下就整句显示,不滚动——这时返回值恒定不变,发布端的"只在变化时才发布"
        // 就天然不会产生任何多余刷新(见 MenuBarMarqueeTicker)。
        guard chars.count > maxChars else { return text }
        let maxOffset = chars.count - maxChars
        // 下限取 1 而不是 0:配 0 的话下面 offset = s - hold + 1 会让第 0 拍就直接是
        // offset 1,整句的开头永远不会露出来(实测这个边界确实会漏字)。"开头至少露一拍"
        // 是这个函数的不变量,不接受被参数配没了;真想"不停留直接滚"也只是少停 0.25 秒,
        // 传 0 和传 1 的观感差异可以忽略。
        let hold = max(1, holdSteps)
        let cycle = maxOffset + hold * 2
        // cycle 恒 > 0(maxOffset >= 1),不用防除零。
        let s = ((step % cycle) + cycle) % cycle // step 传负数也不会崩
        let offset: Int
        if s < hold {
            offset = 0
        } else if s < hold + maxOffset {
            // +1:开头那一段停留(s < hold)本身就是在展示 offset 0,所以停留结束的第一拍
            // 应该已经移动到 1 了。不 +1 的话 offset 0 会被多显示一拍,"停留 holdSteps
            // 拍"就名不副实(实际停 holdSteps+1 拍)。
            offset = s - hold + 1
        } else {
            offset = maxOffset
        }
        return String(chars[offset ..< offset + maxChars])
    }
}

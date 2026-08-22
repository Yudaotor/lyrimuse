import AppKit
import CoreGraphics

// 把一块屏幕映射成一个**跨插拔、跨重启都稳定**的字符串 ID,给"灵动岛显示在哪块屏幕"
// 这个设置项持久化用。
//
// 两个更省事但都不成立的选项:
//   - NSScreen.localizedName —— 同型号的两块外接显示器会重名(都叫 "LS27B61x"),
//     存下来根本分不清是哪一块。
//   - deviceDescription 里的 NSScreenNumber(CGDirectDisplayID)—— 那是系统在本次
//     会话里临时分配的编号,拔掉再插回来、换个接口、或者重启一次就可能变成另一个
//     数字,存进偏好里下次就指到别的屏幕(或者谁都指不到)。
//
// CGDisplayCreateUUIDFromDisplayID 给的是显示器自身的 UUID,正是为"跨会话记住某一块
// 具体屏幕"准备的。数组下标同样不能用:插拔顺序会变。
enum ScreenIdentity {
    static func id(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        // Create 规则:CGDisplayCreateUUIDFromDisplayID 返回的是 +1 引用,takeRetainedValue。
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // 找不到就返回 nil —— 指定的那块屏幕现在没接着(拔了/合盖了)是完全正常的情况,
    // 调用方应该退回"自动",而不是因为记着一块不存在的屏幕就干脆不显示。
    static func screen(withID id: String) -> NSScreen? {
        guard !id.isEmpty else { return nil }
        return NSScreen.screens.first { self.id(of: $0) == id }
    }

    // 有真刘海的那块屏(safeAreaInsets.top > 0)。"灵动岛"这个形态本来就长在刘海上,
    // 没有明确指定时它就是最合理的默认目标。
    static var notched: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}

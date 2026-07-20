import Foundation
import CoreServices

// 查/请求"自动化"权限(允许这个 App 用 Apple Event 控制 Music.app)——只覆盖
// Lyrimuse 自己这一份身份,给 AppleMusicPositionClient 读精确播放进度用。
// collector 采集器是完全独立的系统进程/独立签名身份,自己也会发同类 Apple Event
// (专辑预取、它自己的精确进度),但那是 TCC 数据库里单独一条记录——这里没有任何
// API 能查到或触发它,设置页面对 collector 那份只给一句说明文字+跳系统设置的按钮。
//
// 用到的 AEDeterminePermissionToAutomateTarget/AECreateDesc 是老的 Apple Event
// Manager API,在这台机器上已经用一次性测试脚本实测验证过:noErr(0)=已授权、
// errAEEventNotPermitted(-1743)=已拒绝、errAEEventWouldRequireUserConsent(-1744)=
// 还没问过(askIfNeeded=false 时不会弹窗,只读现状)、procNotFound(-600)=目标应用
// 标识符查不到(极端情况,当"还没问过"处理)。event class/id 用 typeWildCard 是
// Apple 文档里"查这个 App 整体自动化权限"的标准写法,不是针对某个具体事件。
enum MusicAutomationPermissionStatus {
    case authorized
    case denied
    case notDetermined

    var isAuthorized: Bool { self == .authorized }
}

enum MusicAutomationPermission {
    private static let musicBundleID = "com.apple.Music"

    // askIfNeeded=true 且当前还没问过时,这一步会真的弹出系统的自动化授权对话框——
    // 跟第一次真的发送 Apple Event 弹出的是同一个系统机制,不是自己画的假弹窗。
    // 已经问过(不管授权还是拒绝)时,系统不会重复弹窗,直接照原样返回结果。
    @discardableResult
    static func check(askIfNeeded: Bool) -> MusicAutomationPermissionStatus {
        var target = AEAddressDesc()
        let bundleIDBytes = Array(musicBundleID.utf8)
        guard AECreateDesc(
            DescType(typeApplicationBundleID),
            bundleIDBytes,
            bundleIDBytes.count,
            &target
        ) == noErr else {
            return .notDetermined
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askIfNeeded
        )
        switch status {
        case noErr:
            return .authorized
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            // errAEEventWouldRequireUserConsent(-1744)/procNotFound(-600)/其它任何
            // 没见过的返回值,都当"还没有确定结果"处理——宁可多问一次,也不要把
            // 一个模糊状态误判成"已拒绝"从而永远不再给用户开口的机会。
            return .notDetermined
        }
    }

    // 系统设置里"隐私与安全性 → 自动化"面板——被拒绝后官方没有 API 能再触发一次
    // 系统弹窗,只能引导用户自己去这里手动打开;跟 collector 那份权限共用同一个
    // 面板,一个跳转按钮足够覆盖两边的"去看看"需求。
    static var systemSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    }
}

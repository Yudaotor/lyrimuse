import Foundation

/// `lyrimuse://settings/<路径>` 指向的设置页。路径是对外契约:发版说明、支持回复、本机不点界面
/// 核对某一页外观都用它;改名要同步 14 章「深链」那条与 lyrimuse-verify-ui skill。
///
///     /lyrics /player /appearance /shortcuts /general /about    顶层分类(= App 里 SettingsTab 的 rawValue)
///     /account/listenbrainz /account/lastfm /account/relay /account/bark /account/discord    账号页
///     /software-update       软件更新页(App 侧另认 ?check=1)
///     /lastfm-suggestions    Last.fm 账号建议页
///
/// 认不出的路径返回 nil,App 只把设置窗口叫出来、停在上次的分类。大小写不敏感。
public enum SettingsDeepLink: Equatable {
    case tab(String)
    case account(Account)
    case softwareUpdate
    case lastfmSuggestions

    public enum Account: String, CaseIterable {
        case listenbrainz, lastfm, relay, bark, discord
    }

    /// 顶层分类的路径名。必须与 App 的 SettingsTab 的 case 一一对应(selftest settings-ui 组的契约守着)。
    public static let tabNames = ["lyrics", "player", "appearance", "shortcuts", "general", "about"]

    public init?(path: String) {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        if parts.count == 1 {
            switch parts[0] {
            case "software-update": self = .softwareUpdate
            case "lastfm-suggestions": self = .lastfmSuggestions
            default:
                guard Self.tabNames.contains(parts[0]) else { return nil }
                self = .tab(parts[0])
            }
        } else if parts.count == 2, parts[0] == "account", let account = Account(rawValue: parts[1]) {
            self = .account(account)
        } else {
            return nil
        }
    }
}

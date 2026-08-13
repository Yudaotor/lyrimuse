import Foundation

/// 导入外来配置时的最小安全策略。
///
/// 背景:配置包一直是"用户自己从这台机器导出、拿到另一台机器导入",两端都可信,所以
/// `importData` 是把 `config` 段**原样序列化盖掉** config.json 的,零字段校验。
/// 2026-08-13 加"自选备份文件夹"之后这个前提变了 —— 用户可以把备份目录指向一个共享的
/// Dropbox / 团队盘,那个目录里的文件就成了导入源,而它未必只有用户自己能写。
///
/// 这里刻意**不做全字段白名单**:ConfigStore 是整字典读写的,就为了保住 `api_root` /
/// `media_control_path` / `bundle_ids` 这些当前 UI 不管、但 collector 要用的字段
/// (见 ConfigStore 文件头)。白名单会把它们连坐删掉,把一个安全措施变成数据损坏。
/// 只挑真正危险的那一类管:**能让数据发到别处去的地址**。
public enum ImportPolicy {
    /// `state_relay_url` 能不能用。
    ///
    /// 这个字段决定收听状态往哪台服务器推,而 collector 侧(relay.go)是拿到什么用什么、
    /// 不校验 scheme,并且会把 `state_relay_token` 放进请求头一起发出去。一份被人改过的
    /// 配置只要把它换成自己的地址,就能持续收走你的播放记录和那把 token。
    ///
    /// 规则:
    /// - `https` 放行。
    /// - `http` **只**放行回环地址 —— 本地起个服务调试是合理需求,但明文往公网发 token 不是。
    /// - 其余(含 `file:`、自定义 scheme、解析不出来的串)一律拒绝。
    ///
    /// 空串不归这里管:空表示"没配置这个功能",由调用方先行判断。
    public static func isAcceptableRelayURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased()
        else { return false }

        switch scheme {
        case "https":
            // 有 scheme 还不够,得真有个 host —— "https://" 这种解析得出 scheme 但没有主机。
            return !(url.host ?? "").isEmpty
        case "http":
            let host = (url.host ?? "").lowercased()
            return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        default:
            return false
        }
    }
}

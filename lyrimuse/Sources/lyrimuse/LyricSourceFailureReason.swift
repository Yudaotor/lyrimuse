import Foundation

/// collector 侧几个歌词源的"具体失败原因"诊断——两处消费:设置页「歌词来源」卡片的
/// 测试按钮(`LyricSourceTestService`/`SettingsView.sourceAccessoryTooltip`)、"联网搜索
/// 候选歌词"弹窗的"歌词源可用情况"明细(`LyricsSearchService`/`LyricsSearchSheet`)。
///
/// 2026-09-01 从**自然语言文案**改成**稳定代码**(用户报"英文界面下这段提示还是中文"
/// 才发现的:collector 那几个 `xxxSetLastFailureReason` 原来写的是硬编码中文句子,经
/// 共享 JSON 原样传到这里直接显示,完全绕开了这个仓库统一走的 `L10n.t()` 本地化机制)。
/// collector 只负责识别"是哪一种已知失败模式"、吐出一个稳定代码(见 collector 侧
/// `lyricsourcefailure.go`),这里负责把代码翻成人话——两侧必须同步维护:collector 加一个
/// 新代码,这个 `switch` 也要补一个 case,漏了的后果是界面显示一串谁都看不懂的代码本身
/// (下面的兜底分支),比"忘了翻译"更难排查。
enum LyricSourceFailureReason {
    static func text(forCode code: String) -> String {
        switch code {
        case "lyricfind_region_restricted":
            return L10n.t("YouTube Music 在这个网络所在地区不可用（地区限制，非网络故障）")
        case "musixmatch_rate_limited":
            return L10n.t("Musixmatch 拒绝了匿名 token 请求（反爬限流，hint=captcha），不是网络故障，稍后重试通常会恢复")
        case "netease_rate_limited":
            return L10n.t("网易云接口限流（短时间内请求过多，操作频繁，code 405），不是网络故障")
        case "musixmatch_direct_blocked":
            // ⚠️ 跟上面的 musixmatch_rate_limited 是完全不同的两回事,别混:那个是服务器
            // **正经回了** 401 hint=captcha(反爬),这个是一个字节都没拿到。2026-09-03 实测
            // 这台机器直连 apic-appmobile.musixmatch.com 那两个 AWS 地址 100% ICMP 丢包、
            // TLS 握手 16 次 0 次成功,而经本机代理立刻 200。用户该做的事也不同:那个是等,
            // 这个是去开代理。
            return L10n.t("Musixmatch 的接口地址在当前网络下直连不通（TCP/TLS 都没有响应），系统代理也不可用——开启代理后通常会恢复")
        // 下面四个是传输层通用代码(2026-09-06,collector 侧 sourcebreaker.go 最后一节的
        // classifyLyricSourceTransportFailure + searchcli.go 派生的 upstream_unreachable),任何源都
        // 可能出现,含义是"这一轮该源一个 HTTP 响应都没拿到 / 根本没法查"。起因是用户报「派对后派对
        // 搜不到」:公司 VPN 下发的 DNS 对六个歌词源的域名一律不答、请求 2ms 内就死在解析这一步,
        // 弹窗却说「九个源都没找到可用的候选」。这四个只在具体代码(上面四个)都没命中时才会出现,
        // 见 searchcli.go 的 lyricSourceFailureReasons。
        case "dns_failed":
            return L10n.t("域名解析失败（DNS），请求根本没发出去——常见于 VPN / 公司网络接管了 DNS；浏览器能开网页不代表这里能通")
        case "connect_failed":
            // 刻意**不**说"域名能解析":DNS 挂住被 Client.Timeout 掐断时 collector 靠 httptrace 才能
            // 认出来,复用连接 / DoH 自定义拨号那两条路拿不到轨迹,这一档兜的是"DNS 之外的一切"。
            return L10n.t("连接失败或超时，没有拿到任何响应")
        case "server_error":
            return L10n.t("服务器报错（HTTP 5xx），稍后重试通常会恢复")
        case "upstream_unreachable":
            // 目前只有 AMLL 会报:它不做搜索,只按网易云 / QQ 给出的曲目 ID 取词,两者都连不上时它
            // 一个请求都没发 —— 不是"查过了没有",是"没法查"。
            return L10n.t("依赖的上游源（网易云 / QQ音乐）没连上，这一轮没法查")
        // 下面两个是 test-lyric-sources 自己的通用兜底,只有设置页那颗测试按钮会用到
        // (「联网搜索候选歌词」弹窗走的是 lyricSourceFailureReasons,只会吐上面那些代码,
        // 查不到就是 nil、不落到这里)。
        case "no_response":
            return L10n.t("两首探测曲都没有响应，这个源目前可能不可用")
        case "network_down":
            return L10n.t("网络请求全部失败（DNS/连接问题），这一轮探测本身就没跑起来")
        default:
            // 理论不该发生(collector 只会吐上面几个已知代码)——原样显示代码本身,
            // 好过静默吞掉或崩溃,至少排查时能看出"两侧哪个漏了同步"。
            return code
        }
    }
}

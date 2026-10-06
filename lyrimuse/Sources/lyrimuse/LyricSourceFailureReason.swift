import Foundation

/// 引擎侧几个歌词源的"具体失败原因"诊断——两处消费:设置页「歌词来源」卡片的
/// 测试按钮(`LyricSourceTestService`/`SettingsView.sourceAccessoryTooltip`)、"联网搜索
/// 候选歌词"弹窗的"歌词源可用情况"明细(`LyricsSearchService`/`LyricsSearchSheet`)。
///
/// 从**自然语言文案**改成**稳定代码**:引擎那几个 `xxxSetLastFailureReason` 原来
/// 写的是硬编码中文句子,经共享 JSON 原样传到这里直接显示,绕开了这个仓库统一走的
/// `L10n.t()` 本地化机制。
/// 引擎只负责识别"是哪一种已知失败模式"、吐出一个稳定代码(见引擎侧
/// `lyricsourcefailure.go`),这里负责把代码翻成人话——两侧必须同步维护:引擎加一个
/// 新代码,这个 `switch` 也要补一个 case,漏了的后果是界面显示一串谁都看不懂的代码本身
/// (下面的兜底分支),比"忘了翻译"更难排查。
enum LyricSourceFailureReason {
    static func text(forCode code: String) -> String {
        switch code {
        case "lyricfind_region_restricted":
            return L10n.t("YouTube Music 在当前网络所在地区不可用（地区限制，并非网络故障）")
        case "musixmatch_rate_limited":
            return L10n.t("Musixmatch 拒绝了匿名令牌请求（反爬限流，hint=captcha），并非网络故障，稍后重试通常可恢复")
        case "netease_rate_limited":
            return L10n.t("网易云音乐接口限流（短时间内请求过多，code 405），并非网络故障")
        case "deezer_auth_failed":
            // Deezer 取词要先从 auth.deezer.com 换一张匿名 JWT(不需要账号),这一步没换到。
            // 这是这一路目前**唯一**实测见过的失败模式——"这首歌没有歌词"是正常结果、
            // 不会报到这里来。 这个 case 曾经是 deezer_region_restricted,那是误判:
            // 当时走的旧接口对任何歌都回 "No lyrics id ... and country XX",换出口到别的
            // 国家照样如此,真因是那条接口废了,见 lyrimuse-engine/deezer.go 头注。
            return L10n.t("无法从 Deezer 获取匿名访问令牌（并非这首歌曲没有歌词，稍后重试通常可恢复）")
        case "applemusic_not_connected":
            // 这一条不是故障:Apple Music 的歌词端点只认订阅用户的 media-user-token,
            // 用户还没在设置里连过账号时就是这个码。文案要指路,不要像别的码那样报"失败"。
            return L10n.t("尚未连接 Apple Music。可在「歌词来源」卡片底部点按「连接」登录（需要 Apple Music 订阅）")
        case "applemusic_token_rejected":
            // Apple 的令牌固定 6 个月且不发可续期令牌,到期只能重登一次。
            return L10n.t("Apple Music 的登录已过期或被吊销（有效期 6 个月，Apple 不提供自动续期），请在「歌词来源」卡片底部重新连接")
        case "applemusic_no_developer_token":
            return L10n.t("无法获取 Apple Music 接口的公共访问令牌（无法连接 music.apple.com），可能是网络问题，稍后重试通常可恢复")
        case "soda_endpoint_changed":
            // 这一条报的是**接口本身变了**,不是"这首歌没词"。汽水的取词走的是给搜索
            // 引擎爬的 SEO 端点、不是稳定契约(同一客户端的 PC 接口已经整个下线过一次),
            // 所以它改了形状要能说出来,而不是退化成"汽水一直没有歌词"。
            // 另外两种结局都不会走到这里:曲库里有这首歌但没给词(正常结果)、这首没用汽水
            // 放过所以取不到曲目 id(这一路的常态)。
            return L10n.t("汽水音乐的歌词接口返回了无法识别的内容（接口可能已变更），并非这首歌曲没有歌词，通常会在后续版本中修复")
        case "musixmatch_direct_blocked":
            // 跟上面的 musixmatch_rate_limited 是完全不同的两回事,别混:那个是服务器
            // **正经回了** 401 hint=captcha(反爬),这个是一个字节都没拿到。实测
            // 这台机器直连 apic-appmobile.musixmatch.com 那两个 AWS 地址 100% ICMP 丢包、
            // TLS 握手 16 次 0 次成功,而经本机代理立刻 200。用户该做的事也不同:那个是等,
            // 这个是去开代理。
            return L10n.t("当前网络无法直接连接 Musixmatch 的接口（TCP/TLS 均无响应），系统代理也不可用；开启代理后通常可恢复")
        // 下面四个是传输层通用代码(引擎侧 sourcebreaker.go 最后一节的
        // classifyLyricSourceTransportFailure + searchcli.go 派生的 upstream_unreachable),任何源都
        // 可能出现,含义是"这一轮该源一个 HTTP 响应都没拿到 / 根本没法查"——跟"曲库里确实
        // 没有这首歌"是两回事,不能把"连不上"报成"没收录"。这四个只在具体代码(上面四个)都没命中时才会出现,
        // 见 searchcli.go 的 lyricSourceFailureReasons。
        case "dns_failed":
            return L10n.t("域名解析失败（DNS），请求未能发出。常见于 VPN 或公司网络接管 DNS 的情况；浏览器能打开网页并不代表此处可以连接")
        case "connect_failed":
            // 刻意**不**说"域名能解析":DNS 挂住被 Client.Timeout 掐断时引擎靠 httptrace 才能
            // 认出来,复用连接 / DoH 自定义拨号那两条路拿不到轨迹,这一档兜的是"DNS 之外的一切"。
            return L10n.t("连接失败或超时，未收到任何响应")
        case "server_error":
            return L10n.t("服务器错误（HTTP 5xx），稍后重试通常可恢复")
        case "upstream_unreachable":
            // 目前只有 AMLL 会报:它不发搜索请求,按曲目 ID 取词、按 ISRC / 歌名只在本地索引里找;索引不在手、
            // 网易云 / QQ 又都连不上时它一个请求都没发 —— 不是"查过了没有",是"没法查"。
            return L10n.t("无法连接所依赖的上游源（网易云音乐 / QQ 音乐），本轮未能查询")
        // 下面两个是 test-lyric-sources 自己的通用兜底,只有设置页那颗测试按钮会用到
        // (「联网搜索候选歌词」弹窗走的是 lyricSourceFailureReasons,只会吐上面那些代码,
        // 查不到就是 nil、不落到这里)。
        case "no_response":
            return L10n.t("两首探测曲均无响应，该源目前可能不可用")
        case "network_down":
            return L10n.t("网络请求全部失败（DNS / 连接问题），本轮探测未能执行")
        default:
            // 理论不该发生(引擎只会吐上面几个已知代码)——原样显示代码本身,
            // 好过静默吞掉或崩溃,至少排查时能看出"两侧哪个漏了同步"。
            return code
        }
    }
}

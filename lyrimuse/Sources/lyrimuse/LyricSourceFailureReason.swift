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
        // 下面两个是 test-lyric-sources 自己的通用兜底,只有设置页那颗测试按钮会用到
        // (「联网搜索候选歌词」弹窗走的是 lyricSourceFailureReasons,只覆盖上面三个具体
        // 代码,查不到就是 nil、不落到这里)。
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

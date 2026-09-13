package main

// 三个歌词源(netease/musixmatch/lyricfind)已经接了具体失败原因诊断(2026-08-31,
// 分别见 ytmusic.go/musixmatch.go/netease.go 头注——每一条都是实测复现过、不是猜的),
// 两处消费:设置页"歌词来源"卡片的测试按钮(testlyricsourcescli.go)、"联网搜索候选歌词"
// 弹窗的"歌词源可用情况"明细(searchcli.go 的 lyricSourceFailureReasons)。
//
// ⚠️ 2026-09-01 从**自然语言文案**改成**稳定代码**(用户报"英文界面下这段提示还是中文"
// 才发现的:xxxSetLastFailureReason 写的是硬编码中文句子,经共享 JSON 原样传到 Swift 侧
// 直接显示,完全绕开了这个仓库其它地方统一走的 L10n.t() 本地化机制——不是漏翻译一个
// 字符串,是这一整条数据通路从设计上就没有本地化的概念)。collector 只负责识别"是哪一种
// 已知失败模式",不负责把它组织成人话——人话(不管中文还是英文)交给 Swift 侧的
// LyricSourceFailureReason.text(forCode:) 按 App 界面语言翻译。两侧改动必须同步:
// 这里加一个新代码,Swift 那边的 switch 也要补一个 case,漏了的后果是界面显示一串
// 谁都看不懂的代码本身(兜底分支),比"忘了翻译"更难排查,所以两处都各自留了醒目的
// "两侧必须同步"提醒。
const (
	lyricFailureReasonLyricFindRegionRestricted = "lyricfind_region_restricted"
	lyricFailureReasonMusixmatchRateLimited     = "musixmatch_rate_limited"
	lyricFailureReasonNeteaseRateLimited        = "netease_rate_limited"
	// musixmatch_direct_blocked(2026-09-03):apic-appmobile.musixmatch.com 那两个 AWS
	// 地址在当前网络下直连不通(实测 100% ICMP 丢包、TCP 16 次只成功 3 次、TLS 16 次
	// 0 次成功),而 proxyfallback.go 的系统代理兜底也没能救回来(没配代理,或者配了但
	// 连不上)。跟 musixmatch_rate_limited 是完全不同的两回事:那个是服务器**正经回了**
	// 401 hint=captcha,这个是一个字节都没拿到。
	lyricFailureReasonMusixmatchDirectBlocked = "musixmatch_direct_blocked"
	// deezer_auth_failed(2026-09-13):取词要先从 auth.deezer.com 换一张**匿名 JWT**,
	// 这一步没换到(端点不答、非 200、或响应里没有 jwt 字段)。这是这一路目前**唯一**
	// 实测见过的失败模式 —— "这首歌没有歌词"(GraphQL 的 LyricsNotFoundError)是正常
	// 结果,不往这里记,报上去会让用户以为源坏了。见 deezer.go 头注。
	// ⚠️ 这里曾经有过一个 deezer_region_restricted,是**误判**:当时走的 gw-light.php
	// song.getLyrics 对任何歌都回 "No lyrics id ... and country XX",那句话里的国家极具
	// 误导性;换出口到 US 照样是同一句,song.getData 更显示 LYRICS_ID 对所有歌恒为 0 ——
	// 是那条旧接口废了,跟国家无关。整条取词路径已改走 pipe.deezer.com。
	lyricFailureReasonDeezerAuthFailed = "deezer_auth_failed"
)

// 传输层通用代码(2026-09-06,用户报「为什么这首歌搜不到」:九个源里六个在 DNS 解析这一步
// 就死了,弹窗却说「九个源都没找到可用的候选」,把"连不上"报成了"没收录")。由 sourcebreaker.go
// 的 classifyLyricSourceTransportFailure 按 http.Client.Do 的错误 / 状态码分类、按请求主机归源
// (lyricSourceForHost),「搜索候选歌词」弹窗对**这一轮一个 HTTP 响应都没拿到**的源报出来
// (searchcli.go 的 lyricSourceFailureReasons)。跟上面几个"某源特有"的代码不同,这三个对任何源
// 都可能出现;具体代码(限流 / 地区限制 / 直连被堵)优先,这三个只填空。同样"稳定代码不是文案",
// Swift 侧的 switch 要同步补 case(守卫见 lyricsourcefailure_test.go)。
const (
	// 域名解析失败 —— 请求根本没发出去。两条判据任一命中:httptrace 的 DNS 阶段没走完 /
	// 带错(覆盖 DNS 挂住被 Client.Timeout 掐断、错误链已被换掉的情形),或错误链里有
	// *net.DNSError(秒答的 NXDOMAIN / SERVFAIL)。见 sourcebreaker.go 最后一节的 ⚠️ 段。
	lyricFailureReasonDNSFailed = "dns_failed"
	// 连接 / TLS / 读响应失败或超时,没拿到任何响应。**不断言域名已解析**:复用连接和 DoH
	// 自定义拨号那两条路拿不到 DNS 轨迹,这一档兜的是"除 DNS 已确认失败之外的全部传输层失败"。
	lyricFailureReasonConnectFailed = "connect_failed"
	// 拿到了响应,但全是 5xx。4xx 不算:那是服务器在正经说话(404 = 没这首、403 = 反爬),
	// 各源自己判定,跟 sourcebreaker.go 的口径一致。
	lyricFailureReasonServerError = "server_error"
	// 上游没连上、这一轮根本没法查。目前只有 amll 会报:它不做搜索,只按网易云 / QQ 给出的
	// 曲目 ID 去 raw.githubusercontent.com 取词(amllttml.go amllLyric),两个 ID 都拿不到时一个
	// 请求都不发 —— 于是它在传输层表里没有条目、不是 dns_failed 也不是 connect_failed,却也
	// 绝不是"查过了没有"。评审时抓到的漏洞:不给它归因,弹窗会把它算进「其余 N 个源」,而
	// 「歌词源全都没连上」那一档在网易云 + QQ 一起死掉时永远触发不了(amll 默认开着)。
	// 由 searchcli.go 的 lyricSourceFailureReasons 派生(条件:amll 这轮为缺 ID 而跳过 +
	// 网易云和 QQ 都带传输层代码),不经 sourcebreaker.go。
	lyricFailureReasonUpstreamUnreachable = "upstream_unreachable"
)

// 下面两个是 testlyricsourcescli.go 自己的通用兜底(没有命中上面任何一条具体已知失败
// 信号时用)——跟上面那些代码同一套"稳定代码,不是文案"的约定,只是作用域窄一些
// (只有 test-lyric-sources 这条 CLI 用,不需要在多个源文件之间共享,但放在同一个文件里
// 方便一眼看全这一整套代码枚举)。
const (
	lyricTestReasonNoResponse  = "no_response"
	lyricTestReasonNetworkDown = "network_down"
)

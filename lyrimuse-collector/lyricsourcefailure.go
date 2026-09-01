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
)

// 下面两个是 testlyricsourcescli.go 自己的通用兜底(没有命中上面任何一条具体已知失败
// 信号时用)——跟上面三个具体代码同一套"稳定代码,不是文案"的约定,只是作用域窄一些
// (只有 test-lyric-sources 这条 CLI 用,不需要在多个源文件之间共享,但放在同一个文件里
// 方便一眼看全这一整套代码枚举)。
const (
	lyricTestReasonNoResponse  = "no_response"
	lyricTestReasonNetworkDown = "network_down"
)

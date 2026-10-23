package main

import (
	"fmt"
	"strings"
	"time"
)

// 冒用上游客户端身份的那些硬编码参数(客户端版本号、app_id、签名盐、设备串)的登记表。
//
// 这些值是逆向或抓包抄来的,上游升级客户端、收紧校验后迟早失效;失效的样子通常不是报错,而是这一路悄悄不给、
// 或者降级(逐字退成逐行、带时间戳退成纯文本)。原来散在各个源的文件里,没有一处能看全、也看不出多久没核对了。
// 登记在这里:upstreamidentity_test.go 核对每一项的值跟代码里实际用的一样(改了常量没改这里就红,顺手更新
// VerifiedAt);healthcheck 列出超过 upstreamIdentityStaleAfter 没核对的。
type upstreamIdentity struct {
	Name       string // 是什么
	Where      string // 在哪(文件 / 符号)
	Value      string // 现在的值;签名盐这类只登记前 8 个字符
	VerifiedAt string // 上一次确认这个值还能用(或改成这个值)的日期
	Symptom    string // 失效时的样子
}

var upstreamIdentities = []upstreamIdentity{
	{"QQ 音乐网关(手机版)公共参数 cv", "qq.go qqCommBase", "1003006", "2026-07-13", "musicu.fcg 的详情、歌词请求被拒,回落网页接口"},
	{"QQ 音乐网关搜索(桌面版)参数 cv", "qqfallback.go qqSearchComm", "1859", "2026-09-25", "网关搜索回 request.code 2001,回落 client_search_cp"},
	{"QQ 音乐 lyric_download 版本号", "qqfallback.go qqLyricDownloadAt", "15/82", "2026-10-02", "备用链取不到 QRC,逐字退成逐行"},
	{"QQ 音乐 smartbox cv", "qq.go qqSmartboxAt", "4747474", "2026-09-25", "联想搜索不给结果"},
	{"YouTube Music 安卓客户端版本", "ytmusic.go ytmusicMobileClientVersion", "7.21.50", "2026-08-31", "lyricfind 带时间戳歌词 404,退成纯文本"},
	{"Musixmatch app_id", "musixmatch.go musixmatchAppID", "mac-ios-v2.0", "2026-09-28", "拿不到 usertoken 或回 captcha,整源暂停"},
	{"咪咕 jadeite 签名盐", "migu.go miguJadeiteSignSalt", "yyapp2d1", "2026-10-01", "备用搜索签名不过,回落主搜索"},
	{"汽水音乐搜索 aid", "soda.go sodaSearchAID", "386088", "2026-09-21", "搜索回空,回落分享页"},
	{"酷狗网页版搜索签名盐", "kugousongpage.go kugouSearchSignSalt", "NVPh5oo7", "2026-10-23", "签名搜索回 status 0,酷狗在放的歌没有网页歌曲页"},
}

// upstreamIdentityStaleAfter:登记的值多久没核对就在 healthcheck 里提一句。
const upstreamIdentityStaleAfter = 180 * 24 * time.Hour

// staleUpstreamIdentities:超过 upstreamIdentityStaleAfter 没核对的那几项,每项一句「名字(上次核对日期)」。
func staleUpstreamIdentities(now time.Time) []string {
	var out []string
	for _, u := range upstreamIdentities {
		at, err := time.ParseInLocation("2006-01-02", u.VerifiedAt, time.Local)
		if err != nil || now.Sub(at) > upstreamIdentityStaleAfter {
			out = append(out, fmt.Sprintf("%s(%s,%s)", u.Name, u.VerifiedAt, u.Where))
		}
	}
	return out
}

// upstreamIdentitySummary:healthcheck 那一行的正文。
func upstreamIdentitySummary(now time.Time) (stale bool, text string) {
	if s := staleUpstreamIdentities(now); len(s) > 0 {
		return true, fmt.Sprintf("%d 项超过 %d 天没核对,上游升级后可能已经失效:%s", len(s),
			int(upstreamIdentityStaleAfter.Hours()/24), strings.Join(s, ";"))
	}
	return false, fmt.Sprintf("%d 项都在 %d 天内核对过", len(upstreamIdentities), int(upstreamIdentityStaleAfter.Hours()/24))
}

package main

import (
	"math"
	"unicode"
)

// sameRecordingLengthSecs:候选自报曲长跟本地差这么多以内才算同一条录音的长度。各平台多报整数秒,1 秒容得下取整;
// 两场演出同一首歌的长度差个两三秒很常见(方大同《南音》大事发声 290.65s 对 Timeless 288s,差不到 1%),所以按秒不按比例。
const sameRecordingLengthSecs = 1.0

func sameRecordingLength(localSecs, candSecs float64) bool {
	return localSecs > 0 && candSecs > 0 && math.Abs(localSecs-candSecs) <= sameRecordingLengthSecs
}

// sameLiveShowNamedInOtherLanguage:liveAlbumIdentityConflict 判成两场演出的这一对,其实是同一场的中英两种叫法 ——
// 两个专辑名一个整个是英文、一个整个是中文(albumNamedInOtherLanguage),身份词本来就不可能相交;再加上候选自报曲长
// 跟本地差不到 1 秒(sameRecordingLength)。光看名字分不出来:「Jay Chou The Invincible Concert Tour」对
// 「周杰伦地表最强世界巡回演唱会」(213s 对 213.28s)是同一场,方大同「大事发声.录音棚现场」对「Timeless演唱会」
// (290.65s 对 288s)是两场。
func sameLiveShowNamedInOtherLanguage(localAlbum string, durationSecs float64, c lyricCandidate) bool {
	return albumNamedInOtherLanguage(localAlbum, c.album) && sameRecordingLength(durationSecs, c.sourceReportedDurationSecs)
}

// albumNamedInOtherLanguage:一个专辑名只有汉字以外的字母(拉丁字母,也包括假名、谚文)、另一个只有汉字,live / 演唱会
// 这类通用标记词和数字不算。看整个
// 专辑名(连歌手名一起),不看剥掉歌手名后的身份词:「The One 周杰伦演唱会」剥掉歌手名只剩英文,其实是中英混写的名字,
// 对「2004 无与伦比演唱会」不能当成同一场的另一种叫法。
func albumNamedInOtherLanguage(a, b string) bool {
	aOther, aHan := albumNameScripts(a)
	bOther, bHan := albumNameScripts(b)
	return (aOther && !aHan && bHan && !bOther) || (aHan && !aOther && bOther && !bHan)
}

func albumNameScripts(album string) (other, han bool) {
	for t := range albumTokens(toSimplified(album)) {
		if liveAlbumMarkerTokens[t] {
			continue
		}
		for _, r := range t {
			switch {
			case unicode.Is(unicode.Han, r):
				han = true
			case unicode.IsLetter(r):
				other = true
			}
		}
	}
	return other, han
}

// verifiedRecordingTitle:这一批候选里由 Apple 原产地商店那条反查(title-from-apple-storefront,按专辑定位或按 ISRC
// 认出这一条录音)改写过的正式歌名,没有返回 ""。别的反查(按专辑纯时长、歌手泛搜、按歌词搜)只是猜,不算。
func verifiedRecordingTitle(rounds ...[]scoredLyricCandidateResult) string {
	for _, rs := range rounds {
		for _, r := range rs {
			if r.RetryMethod == lyricQueryReasonTitleStorefront && r.RetriedTitle != "" {
				return r.RetriedTitle
			}
		}
	}
	return ""
}

// applyVerifiedTitleVersion:正式歌名(verifiedRecordingTitle)带着本地标签没写的版本限定词时,版本限定词跟正式歌名
// 对得上的候选标上 verifiedTitleVersionAgrees,打分时不按本地标签判版本不符。Amazon 上的「Jay Chou - Rice Field」
// (143s)原产地商店认出是《稻香 (Remix搖滾版)》,各源给的正是这一版,却因为本地歌名没写 Remix 各扣了 -600。
// 候选自报曲长还得跟本地差不到 1 秒(sameRecordingLength):正式歌名是这一条录音的,长度对不上的另一版不沾光;歌词自己的
// [ti:] 也不能带出正式歌名里没有的限定词(lyricHeaderClaimsOtherVersion 按正式歌名再判一次)—— 标上之后打分时标题、
// 歌词头两条版本判据都不再按本地标签扣。
// 跟本地标签对得上的候选照旧按本地标签判,两种写法都认。跟 applyLanguageVersionVerdicts 一样是批级、在打分之前。
func applyVerifiedTitleVersion(localTitle, localAlbum string, durationSecs float64, verifiedTitle string, cands []lyricCandidate) {
	if verifiedTitle == "" || !versionTagsMismatch(localTitle, localAlbum, verifiedTitle, localAlbum) {
		return
	}
	for i := range cands {
		c := &cands[i]
		c.verifiedTitleVersionAgrees = (c.title != "" || c.album != "") && sameRecordingLength(durationSecs, c.sourceReportedDurationSecs) &&
			!versionTagsMismatch(verifiedTitle, localAlbum, c.title, c.album) &&
			!lyricHeaderClaimsOtherVersion(verifiedTitle, localAlbum, durationSecs, c.lyrics, c.album, c.sourceReportedDurationSecs)
	}
}

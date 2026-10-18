package main

import (
	"math"
)

// 区服遍历按时长挑出来的曲目(曲名跟本地不同,appleStorefrontPickTrack 第②步)只在有反证时不用:定位到的店面专辑可能是
// 别人的同名专辑、同一位艺人的另一张专辑,本地这首根本不在里面。查不到证据时照旧用,对的别名(「死神」→「Shinigami」、
// 「一坪半」→「4.95m² Dream」)一条都不挡。别拿 iTunes 的 artistId 判是不是同一个人:同一个人常有几个艺人页(「G.E.M.」和
// 「G.E.M. 鄧紫棋」、「David Tao」和「陶喆」)。见 09 章决策 286。

// storefrontHit:区服遍历一个商店挑中的曲目和那张专辑的曲目表。cross:曲名跟本地不同(只凭时长挑的);titleOK:曲名能当规范曲名。
type storefrontHit struct {
	country string
	hit     itunesResult
	tracks  []itunesResult
	cross   bool
	titleOK bool
}

// appleStorefrontAlbumFingerprintMinTracks / ToleranceSecs:专辑时长指纹。本地同一张专辑听过的歌少于这个数不判;两边曲目时长差在
// 容差内算对得上,容差同 appleStorefrontCrossScriptToleranceSecs。
const (
	appleStorefrontAlbumFingerprintMinTracks     = 3
	appleStorefrontAlbumFingerprintToleranceSecs = appleStorefrontCrossScriptToleranceSecs
)

// appleStorefrontAlbumMismatch:本地同一张专辑的歌(localDurations,秒)跟店面这张专辑的曲目表对不上 —— 两边曲目数较少的那一边,
// 能在另一边找到时长相近曲目的不到一半。同一张专辑换了文字、换了版本(加长版、精选重发)时本地那几首都在里面;别人的同名专辑
// 只有巧合。纯函数。
func appleStorefrontAlbumMismatch(localDurations []float64, tracks []itunesResult) bool {
	var store []float64
	for _, t := range tracks {
		if t.TrackTimeMillis > 0 {
			store = append(store, t.TrackTimeMillis/1000)
		}
	}
	if len(localDurations) < appleStorefrontAlbumFingerprintMinTracks || len(store) == 0 {
		return false
	}
	small, large := localDurations, store
	if len(store) < len(localDurations) {
		small, large = store, localDurations
	}
	matched := 0
	for _, d := range small {
		for _, e := range large {
			if math.Abs(d-e) <= appleStorefrontAlbumFingerprintToleranceSecs {
				matched++
				break
			}
		}
	}
	return matched*2 < len(small)
}

// appleStorefrontPickContradiction:按时长挑中的 hit 有没有反证,返回 "album"、"version" 或空串。
//   - album:本地同一张专辑的歌在店面这张专辑里大多找不到(appleStorefrontAlbumMismatch)—— 定位错了专辑。
//   - version:本地歌名 / 专辑名自己写了版本(Live、伴奏之类),跟 hit 的歌名 / 专辑名对不上(versionTagsMismatch)。本地没写版本、
//     店面写了的不判:本地标签可能是坏的(歌名只剩「13」),店面那首的现场版名字正是它的真名。
//
// 纯函数。
func appleStorefrontPickContradiction(localTitle, localAlbum string, hit itunesResult, tracks []itunesResult, localDurations []float64) string {
	if appleStorefrontAlbumMismatch(localDurations, tracks) {
		return "album"
	}
	if len(recordingVersionTags(localTitle, localAlbum)) > 0 && versionTagsMismatch(localTitle, localAlbum, hit.TrackName, hit.CollectionName) {
		return "version"
	}
	return ""
}

// appleStorefrontPickShadowed:别的商店按本地歌名找到了这首(h 以外、曲名相同的那条 g),而 g 的时长跟 h 差出一秒以上、
// g 那张专辑里另有一首(曲名不同)跟 h 时长一样 —— h 是那一首的另一种写法,不是本地这首。纯函数。
func appleStorefrontPickShadowed(localTitle string, h storefrontHit, hits []storefrontHit) bool {
	want := normLoose(localTitle)
	for _, g := range hits {
		if g.cross || math.Abs(g.hit.TrackTimeMillis-h.hit.TrackTimeMillis) <= 1000 {
			continue
		}
		for _, t := range g.tracks {
			if normLoose(t.TrackName) != want && t.TrackTimeMillis > 0 && math.Abs(t.TrackTimeMillis-h.hit.TrackTimeMillis) <= 1000 {
				return true
			}
		}
	}
	return false
}

// localAlbumTrackDurations:enrich 缓存里同一位艺人、同一张专辑(都按 normLoose 比)的歌的时长,每首歌名只算一次。
// 取 enrichMu,调用方不能持有它。
func localAlbumTrackDurations(artist, album string) []float64 {
	na, nal := normLoose(artist), normLoose(album)
	if na == "" || nal == "" {
		return nil
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	seen := map[string]bool{}
	var out []float64
	for key, e := range enrichCache {
		a, t, al := splitEnrichKey(key)
		if normLoose(a) != na || normLoose(al) != nal || seen[normLoose(t)] {
			continue
		}
		d := e.DurationSecs
		if d <= 0 {
			d = e.ResolvedDurationSecs
		}
		if d <= 0 {
			continue
		}
		seen[normLoose(t)] = true
		out = append(out, d)
	}
	return out
}

// mergeStorefrontNames:复核旧结论时的署名:先前记下的在前、这一轮查到的接在后面,去掉这一轮因专辑对不上没收的(rejected,
// 按 normLoose),按 normLoose 去重。纯函数。
func mergeStorefrontNames(cached, fresh []string, rejected map[string]bool) []string {
	seen := map[string]bool{}
	var out []string
	for _, list := range [][]string{cached, fresh} {
		for _, n := range list {
			k := normLoose(n)
			if k == "" || seen[k] || rejected[k] {
				continue
			}
			seen[k] = true
			out = append(out, n)
		}
	}
	return out
}

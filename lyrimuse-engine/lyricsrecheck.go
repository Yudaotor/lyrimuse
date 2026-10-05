package main

import "strings"

// lyricsRecheck:trackEnrichment 这一拍里「已经有词、值得再全源搜一轮」的各个理由。它们起的是同一件事
// (retryLyricsUpgrade,分数严格更高才换),一轮搜索按这一刻的专辑、时长、videoId、播放器把它们一起覆盖,
// 所以起一轮就把这一刻成立的「只来一次」的理由都记成用过了。别拆成一个理由一个分支:几个理由同时成立时
// 会一拍起一轮,接连几轮输入相同、候选一模一样。见 09 章决策 182。
type lyricsRecheck struct {
	// listedAlbum:YouTube Music 登记的专辑判出来了,这份词最近一轮没带着它搜(见 listedAlbumLyricsWorthRecheck)。
	listedAlbum bool
	// kkbox:KKBOX 自己的词在这首被预解析之后才有(见 kkboxLyricsWorthRecheck)。
	kkbox bool
	// amazon:这首当初不是用 Amazon Music 放着解析的,它本地现在有词(见 amazonLyricsWorthRecheck)。
	amazon bool
	// spotify:Musixmatch 当初没给出词,Spotify 缓存里现在有(见 spotifyLyricsWorthRecheck)。
	spotify bool
	// kaset:这份词最近一轮没按这一版的 videoId 问过 Kaset 自家那个源(见 kasetLyricsWorthRecheck)。
	kaset bool
	// retry:升级重试 —— 有源缺席、同源落选、时长对不上(见 needsLyricsRetry)。它没有「只来一次」的记录,
	// 靠条目上的重试时间节流。
	retry bool
}

// lyricsRecheckScene:判这几个理由用的这一拍现场,trackEnrichment 算好传进来(几个播放器缓存里有没有词在锁外算)。
type lyricsRecheckScene struct {
	album, bundleID, kasetVideoID            string
	pinned, wrongDuration                    bool
	kkboxLyrics, amazonLyrics, spotifyLyrics bool
}

// lyricsRecheckForLocked:这一拍成立的理由。「只来一次」的那几个这次进程里用过了就不算。调用方持有 enrichMu。
func lyricsRecheckForLocked(key string, e enrichEntry, s lyricsRecheckScene) lyricsRecheck {
	auto := features().LyricsAutoUpgrade
	return lyricsRecheck{
		listedAlbum: listedAlbumLyricsWorthRecheck(e, s.album, s.pinned, auto) && !listedAlbumLyricsRechecked[key],
		kkbox:       kkboxLyricsWorthRecheck(e, s.bundleID, s.pinned, auto, s.kkboxLyrics) && !kkboxLyricsRechecked[key],
		amazon:      amazonLyricsWorthRecheck(e, s.bundleID, s.pinned, auto, s.amazonLyrics) && !amazonLyricsRechecked[key],
		spotify:     spotifyLyricsWorthRecheck(e, s.bundleID, s.pinned, auto, s.spotifyLyrics) && !spotifyLyricsRechecked[key],
		kaset: kasetLyricsWorthRecheck(e, s.bundleID, s.kasetVideoID, kasetAudioVideoIDFor(s.kasetVideoID), s.pinned, auto,
			lyricSourceEnabled("lyricfind")) && !kasetLyricsRechecked[key],
		retry: needsLyricsRetry(e, s.wrongDuration, s.pinned, auto),
	}
}

func (r lyricsRecheck) due() bool {
	return r.listedAlbum || r.kkbox || r.amazon || r.spotify || r.kaset || r.retry
}

// consumeLocked:为这一刻成立的理由起了一轮,把其中「只来一次」的都记成这次进程里用过了。只记成立的那几个:
// 这一拍还不成立的理由(登记专辑没判出来、MV 还没配上音轨版本)以后成立了照常再来。调用方持有 enrichMu。
func (r lyricsRecheck) consumeLocked(key string) {
	if r.listedAlbum {
		listedAlbumLyricsRecheckOnce(key)
	}
	if r.kkbox {
		kkboxLyricsRecheckOnce(key)
	}
	if r.amazon {
		amazonLyricsRecheckOnce(key)
	}
	if r.spotify {
		spotifyLyricsRecheckOnce(key)
	}
	if r.kaset {
		kasetLyricsRecheckOnce(key)
	}
}

// String:成立的理由,逗号分隔,记进这一轮决策日志那一行(reasons=)。
func (r lyricsRecheck) String() string {
	var out []string
	for _, x := range []struct {
		on   bool
		name string
	}{
		{r.listedAlbum, "listed-album"}, {r.kkbox, "kkbox"}, {r.amazon, "amazon"},
		{r.spotify, "spotify"}, {r.kaset, "kaset"}, {r.retry, "retry"},
	} {
		if x.on {
			out = append(out, x.name)
		}
	}
	return strings.Join(out, ",")
}

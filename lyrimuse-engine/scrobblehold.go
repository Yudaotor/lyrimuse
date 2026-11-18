package main

import (
	"encoding/json"
	"log"
	"os"
	"slices"
	"strings"
	"time"
)

// 测试播放不记收听:命中下面任一条的会话不发 ListenBrainz 的 playing_now / single、不发 Last.fm 的 updateNowPlaying /
// scrobble,也不写本地收听日志和两份待重发队列;网页中继也不把它当「Mac 正在放」推(pushRelayState)。见 12 章决策 98、99。
//
//   - 测试期开关(scrobbleHoldPath):App 的 `lyrimuse://debug/scrobble-hold` 写的租约表,任一租约没到期就算开着。
//     每条租约最长 scrobbleHoldMax,从写入时刻(since)算起,until 写得再远也按这个封顶:忘了关最多吞掉这么久的真实收听。
//   - 测试曲名单(testtracks_generated.go,生成自 shared/test-tracks.json,App 的 Discord「正在听」读同一份):
//     合成测试曲按歌手认;没写歌手标签的现成素材按歌名整串认(歌手为空才看,13 章决策 17)。开关没开也不记。
//
// 判定挂在会话上、只往上棘轮(playSession.scrobbleHold,跟 isAd 同一个形状):开关中途到期或被关掉,已经认成测试的那一首
// 照旧不记;开关中途才打开,下一个出口(正在播放、到点提交、退出兜底、中继推送)就认上。歌词解析不受影响。

// scrobbleHoldMax:一条租约最长多久。App 侧深链的上限(`LyrimuseDeepLink.maxScrobbleHoldMinutes`)跟它相同,两处一起改。
const scrobbleHoldMax = 2 * time.Hour

// scrobbleHoldPath 由 main() 设定;为空(单测、一次性子命令)时开关一律当关着。
var scrobbleHoldPath string

type scrobbleHoldLease struct {
	ID    string `json:"id"`
	Since int64  `json:"since"`
	Until int64  `json:"until"`
}

type scrobbleHoldFile struct {
	Holds []scrobbleHoldLease `json:"holds"`
}

// scrobbleHoldUntil:此刻开着的租约里最晚的到期时刻;没开着返回零值。文件不在、读不了、解析不了都当关着
// (这道闸只拦测试,坏文件不该吞掉真实收听)。
func scrobbleHoldUntil(now time.Time) time.Time {
	if scrobbleHoldPath == "" {
		return time.Time{}
	}
	data, err := os.ReadFile(scrobbleHoldPath)
	if err != nil {
		noteFileErr("read", scrobbleHoldPath, err)
		return time.Time{}
	}
	var f scrobbleHoldFile
	if err := json.Unmarshal(data, &f); err != nil {
		warnf("scrobble hold: cannot parse %s, treating as off: %v", scrobbleHoldPath, err)
		return time.Time{}
	}
	var latest time.Time
	for _, h := range f.Holds {
		since := time.Unix(h.Since, 0)
		// 没写 since、或 since 在将来的租约封顶算不出来,不认。
		if h.Since <= 0 || since.After(now.Add(time.Minute)) {
			continue
		}
		until := time.Unix(h.Until, 0)
		if limit := since.Add(scrobbleHoldMax); until.After(limit) {
			until = limit
		}
		if now.Before(until) && until.After(latest) {
			latest = until
		}
	}
	return latest
}

type testTrackMarks struct {
	ArtistPrefixes []string
	Artists        []string
	UntaggedTitles []string
}

var testTracks = testTrackMarks{ArtistPrefixes: normalizeTestArtists(testTrackArtistPrefixes),
	Artists: normalizeTestArtists(testTrackArtists), UntaggedTitles: normalizeTestArtists(testTrackUntaggedTitles)}

// normalizeTestArtists:名单按比对口径(去首尾空白、小写)存一份。App 侧 ScrobbleHold.isTestTrack 同一口径。
func normalizeTestArtists(list []string) []string {
	out := make([]string, 0, len(list))
	for _, s := range list {
		out = append(out, strings.ToLower(strings.TrimSpace(s)))
	}
	return out
}

// isTestTrack:歌手是合成测试曲专用的写法,或者歌手为空、歌名是名单里没写歌手标签的测试素材。整串比对或前缀比对,
// 不做子串匹配:名单要窄,真实歌手、真歌不能被带进来。
func isTestTrack(artist, title string) bool {
	a := strings.ToLower(strings.TrimSpace(artist))
	if a == "" {
		t := strings.ToLower(strings.TrimSpace(title))
		return t != "" && slices.Contains(testTracks.UntaggedTitles, t)
	}
	for _, p := range testTracks.ArtistPrefixes {
		if p != "" && strings.HasPrefix(a, p) {
			return true
		}
	}
	for _, x := range testTracks.Artists {
		if a == x {
			return true
		}
	}
	return false
}

// scrobbleHoldReason:这一首此刻该不该挡、因为什么;空串 = 照常记。名单优先,命中名单的不用看开关。
func scrobbleHoldReason(artist, title string, now time.Time) string {
	if isTestTrack(artist, title) {
		return "test track"
	}
	if until := scrobbleHoldUntil(now); !until.IsZero() {
		return "test mode until " + until.UTC().Format(time.RFC3339)
	}
	return ""
}

// heldForTest:会话 s(这一拍的歌手是 artist)要不要挡。第一次判成要挡时记进会话并打一行日志,之后一直挡。
func heldForTest(s *playSession, artist, title string, now time.Time) bool {
	if s.scrobbleHold != "" {
		return true
	}
	reason := scrobbleHoldReason(artist, title, now)
	if reason == "" {
		return false
	}
	s.scrobbleHold = reason
	log.Printf("scrobble hold (%s): %s - %s, no now playing, listens, local listen log or relay card", reason, artist, title)
	return true
}

// curHeldForTest:此刻的曲目(p.cur)是不是测试播放。会话就是这一首时按会话判(认上之后不回落,跟打卡同一个结论);
// 会话还没跟上这一首时直接看名单和开关,不记账。
func (p *poller) curHeldForTest(now time.Time) bool {
	if p.sess != nil && p.sess.key == p.cur.key() {
		return heldForTest(p.sess, p.cur.Artist, p.cur.Title, now)
	}
	return scrobbleHoldReason(p.cur.Artist, p.cur.Title, now) != ""
}

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
	"sync"
	"time"
)

// Last.fm 上"合唱串"艺人的折叠:把 "汪苏泷 & 荷莉" 这种在 Last.fm 编目里根本不存在的
// 合唱署名,在 scrobble 之前收敛成第一位艺人。
//
// 为什么需要:一条 scrobble 只能记一个艺人(Last.fm 版主原话:"cannot add one scrobble
// with a featured artist to both artists")。播放器报的 "A & B" 原样提交上去,匹配不到
// 任何编目条目,Last.fm 会现场造一个只有你一个听众的"影子"艺人/曲目页——没有 mbid、
// 没有专辑、没有时长。结果不是"两个人都记上",而是**两个人都没记上**,credit 全给了那个
// 幽灵字符串,你的 top artists 里凭空多一个假艺人。
//
// 为什么不无脑拆:大量正规署名本身就带分隔符 —— Hall & Oates、Tyler, The Creator、
// Prince & The Revolution、Michael Jackson & Janet Jackson(《Scream》是两人共同署名的
// 单曲,Last.fm 编目里就有这个合体条目、带 mbid)。无脑取第一段会把这些也拆坏,而且
// **不可逆**:Last.fm 的纠错/重定向库目前是冻结的(官方 FAQ:"New corrections CANNOT be
// added to the database"),写错了全局补不回来,Pro 的 bulk edit 也只改自己 library 的显示。
//
// 判据因此用 Last.fm 自己的编目当白名单:拿这首歌按原样查一次 track.getInfo,
//   - 有 mbid,或者听众数够多  → 这是编目里的正规条目,一个字节都不动
//   - 两者都不满足           → 影子条目,折叠成第一位艺人
//
// 这跟 Last.fm 官方的纠错规范(support.last.fm topic 197)第 9/10 条是同一个判断:
// "Only map to such joint artist names if a full release exists under the joint name",
// 拿不准时 "prefer mapping to the more prominently credited artist"。
//
// 2026-08-07 拿本机 558 个不同曲目实测:合唱串 28 首,判定折叠 6 首、保留 22 首。被折叠
// 的 6 首**现状时长全部是 0**——也就是说这道判据只对已经坏掉的条目动手,不存在"本来
// 好好的被折坏"的倒退。其中 2 首折叠后拿回了时长(《Will You Be There》0s→355s、
// 听众 11→278,690;《吵架歌》0s→166s,与真实时长分毫不差),3 首命中度显著提升。
const (
	// 听众数低于这个值 + 没有 mbid,才判定为影子条目。两个信号都要满足才折叠 ——
	// 折叠不可逆,宁可漏折(维持现状)也不能错折。实测影子条目的听众数是 1~180,
	// 而编目里最冷门的正规合体条目(《Scream Louder (Flyte Tyme Remix)》)是 597 且带 mbid。
	lastfmShadowListenersMax = 500
	// 判定结果的缓存有效期。编目会变(冷门歌以后可能被正式收录),但变得很慢,
	// 一个月重查一次足够;更重要的是别让每首歌每次播放都多打一次 API。
	lastfmCollapseTTL = 30 * 24 * time.Hour
)

// lastfmCollapsePath 由 main.go 跟其它落盘路径一起设置。
var lastfmCollapsePath string

type lastfmCollapseDecision struct {
	// Artist 是判定后应该提交的艺人名。跟原串相同表示"保留"。
	Artist string `json:"artist"`
	TS     int64  `json:"ts"`
}

// lastfmArtistCollapser 按上面的判据决定一条 scrobble 该用哪个艺人名。
// 判定结果按 "艺人串\n歌名" 缓存 —— mbid/听众数是**按曲目**查的,同一个合唱串在不同歌
// 上完全可能一个是正规条目、一个是影子条目,不能只按艺人名缓存。
type lastfmArtistCollapser struct {
	apiKey  string // 只读用的 api_key(track.getInfo 不需要签名/session key)
	baseURL string // 可注入,单测用;空则用 Last.fm 正式端点
	hc      *http.Client

	mu    sync.Mutex
	cache map[string]lastfmCollapseDecision
}

func newLastfmArtistCollapser(apiKey string) *lastfmArtistCollapser {
	if apiKey == "" {
		return nil
	}
	c := &lastfmArtistCollapser{
		apiKey: apiKey,
		// 4 秒,不是跟别处一样的 8 秒:这一步是搭在 mirrorAsync 那个**总共 8 秒**的
		// context 里的额外查询,占满就轮不到真正的 scrobble 了。查不动时本来就退回
		// "按原样提交",宁可判不出也不能把提交本身拖死。
		hc:    &http.Client{Timeout: 4 * time.Second},
		cache: map[string]lastfmCollapseDecision{},
	}
	c.load()
	return c
}

// resolve 返回这条 scrobble 应该提交的艺人名。任何一步不确定都返回原串 —— 折叠不可逆,
// 默认行为必须是"维持现状"。
func (c *lastfmArtistCollapser) resolve(ctx context.Context, artist, track string) string {
	if c == nil || artist == "" || track == "" {
		return artist
	}
	// 不含分隔符(或切完只剩一段,如"周杰伦、"这种结尾带分隔符的单人名)就不是合唱串,
	// 直接返回,不打网络。
	if len(artistCreditParts(artist)) < 2 {
		return artist
	}
	primary := firstCreditedArtist(artist)
	if primary == "" || primary == artist {
		return artist
	}

	key := artist + "\n" + track
	if d, ok := c.lookup(key); ok {
		return d
	}

	catalogued, err := c.isCatalogued(ctx, artist, track)
	if err != nil {
		// 查不动(限流/网络/Last.fm 抽风)时不缓存也不折叠:下次再判,别把一次偶发失败
		// 变成一个月的错误决定。
		log.Printf("lastfm collapse: lookup failed for %q / %q: %v (keeping as-is)", artist, track, err)
		return artist
	}
	decided := artist
	if !catalogued {
		decided = primary
		log.Printf("lastfm collapse: %q -> %q (track %q not in catalogue under the joint credit)", artist, primary, track)
	}
	c.store(key, decided)
	return decided
}

// isCatalogued 判断"这首歌按这个艺人串在 Last.fm 编目里是不是一个正规条目"。
func (c *lastfmArtistCollapser) isCatalogued(ctx context.Context, artist, track string) (bool, error) {
	q := neturl.Values{}
	q.Set("method", "track.getInfo")
	q.Set("api_key", c.apiKey)
	q.Set("format", "json")
	q.Set("artist", artist)
	q.Set("track", track)
	// autocorrect=1 让 Last.fm 先套一遍它自己的拼写纠错表再查 —— 纠错后能命中正规条目的
	// 就不该被我们再折叠一次。
	q.Set("autocorrect", "1")

	base := c.baseURL
	if base == "" {
		base = "https://ws.audioscrobbler.com/2.0/"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+q.Encode(), nil)
	if err != nil {
		return false, fmt.Errorf("build request: %w", err)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return false, fmt.Errorf("get track info: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// 404/6 = 这个艺人串下压根没有这首歌 —— 那它连影子条目都不是,同样该折叠。
		// 但其它状态码(429 限流、5xx)是"没查成",不能当结论用。
		if resp.StatusCode == http.StatusNotFound {
			return false, nil
		}
		return false, fmt.Errorf("track.getInfo status %d", resp.StatusCode)
	}
	var body struct {
		Track struct {
			MBID      string `json:"mbid"`
			Listeners string `json:"listeners"`
		} `json:"track"`
		Error int `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return false, fmt.Errorf("decode track.getInfo: %w", err)
	}
	if body.Error == 6 { // "Track not found"
		return false, nil
	}
	if body.Error != 0 {
		return false, fmt.Errorf("track.getInfo error %d", body.Error)
	}
	if body.Track.MBID != "" {
		return true, nil
	}
	listeners, err := strconv.Atoi(body.Track.Listeners)
	if err != nil {
		// 听众数解析不出来时按"有"处理 —— 同样是宁可漏折不错折。
		return true, nil
	}
	return listeners >= lastfmShadowListenersMax, nil
}

func (c *lastfmArtistCollapser) lookup(key string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	d, ok := c.cache[key]
	if !ok || time.Since(time.Unix(d.TS, 0)) > lastfmCollapseTTL {
		return "", false
	}
	return d.Artist, true
}

func (c *lastfmArtistCollapser) store(key, artist string) {
	c.mu.Lock()
	c.cache[key] = lastfmCollapseDecision{Artist: artist, TS: time.Now().Unix()}
	snapshot := make(map[string]lastfmCollapseDecision, len(c.cache))
	for k, v := range c.cache {
		if time.Since(time.Unix(v.TS, 0)) <= lastfmCollapseTTL {
			snapshot[k] = v
		}
	}
	c.cache = snapshot
	c.mu.Unlock()
	c.save(snapshot)
}

func (c *lastfmArtistCollapser) load() {
	if lastfmCollapsePath == "" {
		return
	}
	data, err := os.ReadFile(lastfmCollapsePath)
	if err != nil {
		return // 首次运行没有这个文件是正常的
	}
	var m map[string]lastfmCollapseDecision
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("lastfm collapse: cache unreadable, starting empty: %v", err)
		return
	}
	c.mu.Lock()
	c.cache = m
	c.mu.Unlock()
}

func (c *lastfmArtistCollapser) save(snapshot map[string]lastfmCollapseDecision) {
	if lastfmCollapsePath == "" {
		return
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		log.Printf("lastfm collapse: marshal cache: %v", err)
		return
	}
	// 先写临时文件再 rename,跟 saveEnrichCache 同一个理由(半截文件不能被下次读到);
	// 临时名带 pid,免得两个进程互相覆盖。
	tmp := fmt.Sprintf("%s.tmp.%d", lastfmCollapsePath, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		log.Printf("lastfm collapse: write cache: %v", err)
		return
	}
	if err := os.Rename(tmp, lastfmCollapsePath); err != nil {
		log.Printf("lastfm collapse: rename cache: %v", err)
		_ = os.Remove(tmp)
	}
}

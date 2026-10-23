package main

import (
	"context"
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// 网易云的歌曲动态封面:Apple、QQ 两支都没给出动态封面时,按这条记下的网易云歌曲 id 问 /api/songplay/dynamic-cover(本机抽
// 120 首 26 首有)。这个接口要登录,网易云的游客身份就够:/api/register/anonimous 发一个 MUSIC_A(半年有效),落盘在数据目录
// 里跟 App 共用的那份(neteaseGuestFileName)。画面是方形 mp4(多数 720²、4 秒,是封面本身在微动;少数是十几秒的正式动画),
// 地址带签名、约半小时过期,所以只记歌曲 id:动态封面地址写成 `ncmv:<id>`,App 下载时再换 mp4 地址(MotionCoverStore)。
//
// 引擎不核身份:歌曲 id 本来就是这一首的,画面是不是此刻显示的那张封面交给 App 拿中段帧比(MotionCoverIdentityVerified 为
// false)。结论按 `ne:<id>` 记进动态封面那张缓存表。见 03 章决策 68。

// neteaseMotionCoverScheme:动态封面地址里网易云那一种的前缀,后面是歌曲 id。App 侧按它认(NeteaseMotionCover)。
const neteaseMotionCoverScheme = "ncmv:"

const neteaseDynamicCoverEndpoint = "https://music.163.com/api/songplay/dynamic-cover"

var neteaseSongIDShape = regexp.MustCompile(`^[0-9]{1,20}$`)

// neteaseMotionCoverKey:网易云歌曲在动态封面缓存表里的键。
func neteaseMotionCoverKey(id string) string { return "ne:" + id }

// neteaseDynamicCoverReply:dynamic-cover 应答的几种结局。
type neteaseDynamicCoverReply int

const (
	neteaseDynamicCoverUnknown neteaseDynamicCoverReply = iota // 形状不对、别的 code(含限流的 405):没问成
	neteaseDynamicCoverNone                                    // 问成了、这首没有
	neteaseDynamicCoverFound
	neteaseDynamicCoverLoggedOut // code 301:身份无效
)

// parseNeteaseDynamicCover:应答 → 结局。纯函数,单测覆盖。
func parseNeteaseDynamicCover(body []byte) neteaseDynamicCoverReply {
	var r struct {
		Code int `json:"code"`
		Data *struct {
			VideoPlayURL string `json:"videoPlayUrl"`
		} `json:"data"`
	}
	if json.Unmarshal(body, &r) != nil {
		return neteaseDynamicCoverUnknown
	}
	switch {
	case r.Code == 301:
		return neteaseDynamicCoverLoggedOut
	case r.Code != 200 || r.Data == nil:
		return neteaseDynamicCoverUnknown
	case strings.TrimSpace(r.Data.VideoPlayURL) == "":
		return neteaseDynamicCoverNone
	}
	return neteaseDynamicCoverFound
}

// neteaseDynamicCoverFetch 问一次这首的动态封面。单测替换它。
var neteaseDynamicCoverFetch = func(ctx context.Context, id, cookie string) ([]byte, error) {
	return neteaseFetchBody(ctx, neteaseDynamicCoverEndpoint+"?songId="+id, cookie, 10*time.Second)
}

// neteaseMotionCoverInflight:正在问的网易云歌曲。受 motionCoverMu 保护。
var neteaseMotionCoverInflight = map[string]bool{}

// neteaseMotionCoverFor:这首网易云歌曲的动态封面(`ncmv:<id>`,没有为 "")。第二个返回值同 motionCoverFor:false = 这一轮
// 没查成(没有游客身份、在飞、请求失败、应答形状不对),调用方别据此钉死结论。查过的结论落盘,不再问。
func neteaseMotionCoverFor(ctx context.Context, id string) (string, bool) {
	if !neteaseSongIDShape.MatchString(id) {
		return "", false
	}
	key := neteaseMotionCoverKey(id)
	motionCoverMu.Lock()
	if c, ok := motionCoverCache[key]; ok {
		motionCoverMu.Unlock()
		return c.Master, true
	}
	if neteaseMotionCoverInflight[id] {
		motionCoverMu.Unlock()
		return "", false
	}
	neteaseMotionCoverInflight[id] = true
	motionCoverMu.Unlock()
	defer func() {
		motionCoverMu.Lock()
		delete(neteaseMotionCoverInflight, id)
		motionCoverMu.Unlock()
	}()

	guest, ok := neteaseGuestNow(ctx)
	if !ok {
		return "", false
	}
	body, err := neteaseDynamicCoverFetch(ctx, id, "os=pc; MUSIC_A="+guest)
	if err != nil {
		infoFailf("motion-cover: netease song %s dynamic cover failed: %v", id, err)
		return "", false
	}
	mc := motionCover{Checked: true}
	switch parseNeteaseDynamicCover(body) {
	case neteaseDynamicCoverLoggedOut:
		infoFailf("motion-cover: netease guest identity rejected, registering again next time")
		neteaseForgetGuest(guest)
		return "", false
	case neteaseDynamicCoverUnknown:
		infoFailf("motion-cover: netease song %s dynamic cover answer not recognized", id)
		return "", false
	case neteaseDynamicCoverFound:
		mc.Master = neteaseMotionCoverScheme + id
	}
	motionCoverMu.Lock()
	motionCoverCache[key] = mc
	motionCoverDirty = true
	motionCoverMu.Unlock()
	saveMotionCoverCache()
	if mc.Master != "" {
		log.Printf("motion-cover: netease song %s has motion artwork", id)
	}
	return mc.Master, true
}

// neteaseMotionCoverUnasked:这条已经核过、没有动态封面(对着现在这张封面),记着网易云歌曲 id,而这首还没问过 —— Apple、QQ
// 两支先于网易云这支核出「没有」的存量条目,播到时值得再核一次(trackEnrichment)。只读缓存、不发请求。
// 调用方可以持有 enrichMu(锁顺序 enrichMu → motionCoverMu)。
func neteaseMotionCoverUnasked(e enrichEntry) bool {
	id := neteaseSongIDFromURL(e.NeteaseURL)
	if !e.MotionCoverChecked || e.MotionCoverURL != "" || e.MotionCoverFor != e.CoverURL || !neteaseSongIDShape.MatchString(id) {
		return false
	}
	motionCoverMu.Lock()
	defer motionCoverMu.Unlock()
	_, asked := motionCoverCache[neteaseMotionCoverKey(id)]
	return !asked
}

// motionCoverFallbackUnasked:QQ、网易云两支里有一支对这条还没问过(见 qqMotionCoverUnasked、neteaseMotionCoverUnasked)。
func motionCoverFallbackUnasked(e enrichEntry) bool {
	return qqMotionCoverUnasked(e) || neteaseMotionCoverUnasked(e)
}

// motionVerdictFromNetease:Apple、QQ 两支都没给出动态封面时按网易云歌曲再核,返回有没有定论(同 motionVerdictFromAlbum)。
// checked:前面那两支核出了「没有」(而不是根本没有可核的东西)—— 这边也没有歌曲 id 时,前者记「核过、没有」,后者整组清掉。
func (e *enrichEntry) motionVerdictFromNetease(ctx context.Context, checked bool) bool {
	id := neteaseSongIDFromURL(e.NeteaseURL)
	if !neteaseSongIDShape.MatchString(id) {
		if checked {
			e.recordMotionVerdict("", "", false)
		} else {
			e.clearMotionVerdict()
		}
		return true
	}
	master, done := neteaseMotionCoverFor(ctx, id)
	if !done {
		return false
	}
	e.recordMotionVerdict(master, "", false)
	return true
}

// ---- 游客身份 ----

// neteaseGuestFileName:游客身份那份文件,在数据目录里,App 读写同一份(LyrimuseCore NeteaseMotionCover.guestFileName)。
const neteaseGuestFileName = clientName + "-netease-guest.json"

// neteaseGuest:游客身份。Expires 是 Unix 秒。
type neteaseGuest struct {
	MusicA  string `json:"music_a"`
	Expires int64  `json:"expires"`
}

// usable:离过期还有一天以上。
func (g neteaseGuest) usable(now time.Time) bool {
	return g.MusicA != "" && time.Unix(g.Expires, 0).Sub(now) > 24*time.Hour
}

var (
	neteaseGuestMu       sync.Mutex
	neteaseGuestCached   neteaseGuest
	neteaseGuestBusy     bool
	neteaseGuestRetryAt  time.Time
	neteaseGuestAttempts = 3
	neteaseGuestGap      = 2 * time.Second
	// neteaseGuestCooldown:几次都没注册成之后隔多久再试。注册实测常被间歇拒绝(code 400)。
	neteaseGuestCooldown = 10 * time.Minute
	// neteaseGuestRegister 注册一次。单测替换它。
	neteaseGuestRegister = registerNeteaseGuest
)

func neteaseGuestPath() string {
	dir := configDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, neteaseGuestFileName)
}

func readNeteaseGuestFile(path string) neteaseGuest {
	var g neteaseGuest
	if path == "" {
		return g
	}
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &g)
	}
	return g
}

// neteaseGuestNow:能用的游客身份(MUSIC_A 的值)。内存里、盘上(App 可能先注册了)都没有能用的就注册一次,几次都没成就隔
// neteaseGuestCooldown 再试;别的调用者正在注册时直接回 false。
func neteaseGuestNow(ctx context.Context) (string, bool) {
	now := time.Now()
	path := neteaseGuestPath()
	neteaseGuestMu.Lock()
	if neteaseGuestCached.usable(now) {
		g := neteaseGuestCached.MusicA
		neteaseGuestMu.Unlock()
		return g, true
	}
	if g := readNeteaseGuestFile(path); g.usable(now) {
		neteaseGuestCached = g
		neteaseGuestMu.Unlock()
		return g.MusicA, true
	}
	if neteaseGuestBusy || now.Before(neteaseGuestRetryAt) {
		neteaseGuestMu.Unlock()
		return "", false
	}
	neteaseGuestBusy = true
	neteaseGuestMu.Unlock()

	var g neteaseGuest
	var err error
	for i := 0; i < neteaseGuestAttempts; i++ {
		if i > 0 {
			select {
			case <-time.After(neteaseGuestGap):
			case <-ctx.Done():
				err = ctx.Err()
			}
			if ctx.Err() != nil {
				break
			}
		}
		if g, err = neteaseGuestRegister(ctx); err == nil {
			break
		}
	}
	neteaseGuestMu.Lock()
	defer neteaseGuestMu.Unlock()
	neteaseGuestBusy = false
	if err != nil {
		neteaseGuestRetryAt = time.Now().Add(neteaseGuestCooldown)
		infoFailf("netease: guest registration failed: %v", err)
		return "", false
	}
	neteaseGuestCached = g
	if path != "" {
		if b, mErr := json.Marshal(g); mErr == nil {
			_ = writeFileAtomic(path, b)
		}
	}
	return g.MusicA, true
}

// neteaseForgetGuest:这个身份被拒了,内存里和盘上(还是它的话)都丢掉,下次重新注册。
func neteaseForgetGuest(musicA string) {
	neteaseGuestMu.Lock()
	defer neteaseGuestMu.Unlock()
	if neteaseGuestCached.MusicA == musicA {
		neteaseGuestCached = neteaseGuest{}
	}
	if path := neteaseGuestPath(); path != "" && readNeteaseGuestFile(path).MusicA == musicA {
		_ = os.Remove(path)
	}
}

// neteaseGuestXorKey:游客注册时设备号的混淆密钥。网易云客户端协议里的固定常量,各开源实现通用,不是账号凭据。
const neteaseGuestXorKey = "3go8&$8*3*3h0k(2)2"

// neteaseGuestUsername:游客注册的 username = base64("<设备号> <base64(md5(设备号逐字节异或密钥))>")。纯函数,单测钉着,
// 跟 App 那份(NeteaseMotionCover.guestUsername)用同一组向量。
func neteaseGuestUsername(deviceID string) string {
	x := make([]byte, len(deviceID))
	for i := 0; i < len(deviceID); i++ {
		x[i] = deviceID[i] ^ neteaseGuestXorKey[i%len(neteaseGuestXorKey)]
	}
	sum := md5.Sum(x)
	return base64.StdEncoding.EncodeToString([]byte(deviceID + " " + base64.StdEncoding.EncodeToString(sum[:])))
}

// registerNeteaseGuest:换一个随机设备号注册一次游客。应答 code 不是 200、没发 MUSIC_A 都算失败。
func registerNeteaseGuest(ctx context.Context) (neteaseGuest, error) {
	raw := make([]byte, 26)
	if _, err := rand.Read(raw); err != nil {
		return neteaseGuest{}, err
	}
	u := "https://music.163.com/api/register/anonimous?username=" +
		neturl.QueryEscape(neteaseGuestUsername(strings.ToUpper(hex.EncodeToString(raw))))
	if err := neteaseThrottle(ctx, u); err != nil {
		return neteaseGuest{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return neteaseGuest{}, err
	}
	req.Header.Set("Referer", "https://music.163.com/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Cookie", "os=pc")
	resp, err := doHTTPTracked(lyricHTTPClient(10*time.Second), req)
	if err != nil {
		return neteaseGuest{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return neteaseGuest{}, err
	}
	return neteaseGuestFromReply(resp.StatusCode, body, resp.Cookies(), time.Now())
}

// neteaseGuestFromReply:注册应答 → 游客身份。纯函数,单测覆盖。Cookie 没写有效期时按 150 天算。
func neteaseGuestFromReply(status int, body []byte, cookies []*http.Cookie, now time.Time) (neteaseGuest, error) {
	if status != http.StatusOK {
		return neteaseGuest{}, fmt.Errorf("status %d", status)
	}
	var r struct {
		Code int `json:"code"`
	}
	if json.Unmarshal(body, &r) != nil || r.Code != 200 {
		return neteaseGuest{}, fmt.Errorf("code %d", r.Code)
	}
	for _, c := range cookies {
		if c.Name != "MUSIC_A" || c.Value == "" {
			continue
		}
		g := neteaseGuest{MusicA: c.Value, Expires: now.Add(150 * 24 * time.Hour).Unix()}
		switch {
		case c.MaxAge > 0:
			g.Expires = now.Add(time.Duration(c.MaxAge) * time.Second).Unix()
		case !c.Expires.IsZero():
			g.Expires = c.Expires.Unix()
		}
		return g, nil
	}
	return neteaseGuest{}, errors.New("no MUSIC_A cookie")
}

package main

import (
	"io"
	"log"
	"net/url"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

// 日志脱敏(2026-08-17 加)。
//
// 起因:HTTP 失败几乎都是 `log.Printf("...: %v", err)` 打出来的,而 Go 的 *url.Error
// 在 Error() 里**带上完整请求 URL**。Last.fm 的只读接口把 api_key 放在 query string
// 里,于是一次超时/取消就在 ~/Library/Logs/lyrimuse.log 里留下一行:
//
//	lastfmRecent: request failed: Get "https://ws.audioscrobbler.com/2.0/?...&api_key=<明文>&...": context canceled
//
// 同类的还有钉钉加签(sign 在 query)和 Bark(token 就是 URL 的一段 path)。这个日志
// 文件是用户排查问题时会随手贴出来的东西,不该带凭据。
//
// # 为什么接管 log 的 Writer,而不是在每个打日志的地方套一层脱敏函数
//
// 泄露的是**错误值本身**,而带 %v 打错误的地方有几十处,以后每加一处都得记得套 ——
// 那种"靠每次都不忘"的方案迟早漏,而漏掉的那次没有任何征兆。接管出口是一次性的,
// 之后新写的日志自动受保护。
//
// # 两道防线
//
//  1. **按值**:配置里的凭据在 loadConfig 时登记进来,之后不管它出现在 query、path、
//     请求体还是任何一句话里,都会被替换成 ***。这一道是主力 —— 它不依赖泄露点长什么样。
//  2. **按参数名**:兜住没登记到的(第三方库自带的 key、临时拼的调试 URL),把形如
//     `?api_key=`/`&token=` 的值打掉。这一道只认 query string。
const redactedMark = "***"

const (
	// 太短的串不登记:配置里万一有个两三字符的值,登记进去会把日志打成筛子(比如
	// 一个值恰好是 "ok",满屏的 ok 全变成 ***),反而看不出问题在哪。
	minSecretLen = 8
	// URL path 段的门槛单独设,而且更高:path 段里混着 "messages"、"webhook" 这类
	// 普通词,按 8 会把它们当凭据打掉。Bark 的 token 是 22 字符,16 够用且安全。
	minPathSecretLen = 16
)

var (
	secretsMu     sync.Mutex
	knownSecrets  []string
	secretReplace atomic.Pointer[strings.Replacer]
)

// sensitiveQueryRe 是第二道防线:按**参数名**打掉 query string 里的值。
//
// 词根匹配(key/token/secret/sig/sign/password/auth)覆盖 api_key、access_token、
// api_sig 这些;`sk` 不含任何词根,单列 —— 它是 Last.fm session key 的参数名。
// 值那一段刻意不吃引号/空白/&:错误信息里的 URL 通常被包在双引号里,吃掉引号会把
// 后面的 `: context canceled` 一起吞掉,反而看不出失败原因。
var sensitiveQueryRe = regexp.MustCompile(
	`(?i)([?&](?:sk|[a-z0-9_.\-]*(?:key|token|secret|sig|sign|password|passwd|pwd|auth)[a-z0-9_.\-]*)=)[^&\s"'` + "`" + `]+`)

// registerSecrets 登记一批凭据明文。可以重复调用,内部累积去重。
func registerSecrets(values ...string) {
	registerSecretsMinLen(minSecretLen, values...)
}

func registerSecretsMinLen(minLen int, values ...string) {
	secretsMu.Lock()
	defer secretsMu.Unlock()
	added := false
	for _, v := range values {
		v = strings.TrimSpace(v)
		if len(v) < minLen || slices.Contains(knownSecrets, v) {
			continue
		}
		knownSecrets = append(knownSecrets, v)
		added = true
	}
	if !added {
		return
	}
	// 长的排前面:同一套凭据里短值可能是长值的前缀(或者干脆一个值包含另一个),
	// strings.Replacer 按给定顺序优先匹配,先替短的会在长值中间留下半截明文。
	sorted := slices.Clone(knownSecrets)
	sort.SliceStable(sorted, func(i, j int) bool { return len(sorted[i]) > len(sorted[j]) })
	pairs := make([]string, 0, len(sorted)*2)
	for _, v := range sorted {
		pairs = append(pairs, v, redactedMark)
	}
	secretReplace.Store(strings.NewReplacer(pairs...))
}

// scrubSecrets 对一段将要写进日志的文本做两道脱敏。
func scrubSecrets(s string) string {
	if r := secretReplace.Load(); r != nil {
		s = r.Replace(s)
	}
	return sensitiveQueryRe.ReplaceAllString(s, "${1}"+redactedMark)
}

// rememberConfigSecrets 把配置里的凭据登记进脱敏表。在 loadConfig 里调用,这样每个
// 子命令(它们各自 loadConfig、不走 main 的主流程)都自动受保护,不用逐个记得加。
func rememberConfigSecrets(c *config) {
	if c == nil {
		return
	}
	registerSecrets(
		c.Token,
		c.StateRelayToken,
		c.LastfmAPIKey,
		c.LastfmScrobbleAPIKey,
		c.LastfmScrobbleSecret,
		c.LastfmScrobbleSessionKey,
		c.DingtalkSignSecret,
		c.FeishuSignSecret,
	)
	// Bark 的 token 不是 query 参数,而是 URL 的一段 path(https://api.day.app/<token>),
	// 第二道防线够不着它。只登记 path 段、不登记整条 URL:host 留着,日志里还看得出
	// 这条推送是往哪个平台发的;整条登记也会在 URL 后面拼了标题/正文时直接匹配不上。
	if u, err := url.Parse(c.NotificationWebhookURL); err == nil {
		registerSecretsMinLen(minPathSecretLen, strings.Split(u.Path, "/")...)
	}
}

// secretScrubber 包在 log 的输出 Writer 外面。
type secretScrubber struct{ w io.Writer }

func (s secretScrubber) Write(p []byte) (int, error) {
	cleaned := scrubSecrets(string(p))
	if cleaned == string(p) {
		return s.w.Write(p)
	}
	if _, err := s.w.Write([]byte(cleaned)); err != nil {
		return 0, err
	}
	// 返回 len(p) 而不是实际写出的字节数:脱敏后长度会变(几乎总是变短),而 log 包
	// 把"写出字节数 < 传入长度"当短写错误报出来。调用方要知道的是"这条日志写出去了
	// 没有",不是写了多少字节。
	return len(p), nil
}

// installLogScrubbing 接管标准 log 的输出。main 一进来就调,早于任何配置加载 ——
// 第二道防线(按参数名)不需要配置就能工作。
func installLogScrubbing() {
	log.SetOutput(secretScrubber{w: os.Stderr})
}

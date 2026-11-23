package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/netip"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// 歌词源插件的清单:插件文件开头那段 JSON 注释。这里从插件文件里取出清单、逐项校验、生成运行时登记用的描述符
// (pluginManifest.descriptor)。清单里登记校验(admitDynamicLyricSource)不许的东西在这一层就拒,带规则代码
// (pluginManifestRule*)和给人看的原因。校验过的这一份留在引擎这边:白名单、限额、轮次、平台曲目编号的键都按它判,
// 发给 plugin-host 的只是原文(Raw)。见 09 章决策 402。

const (
	// pluginFileMaxBytes:插件文件的大小上限。
	pluginFileMaxBytes = 512 << 10
	// pluginManifestMarker:清单注释的开头,必须是插件文件里的第一样东西(前面只许有 BOM 和空白)。
	pluginManifestMarker = "/* @lyrimuse-plugin"
	// pluginAPIVersion:这一版引擎认的清单 apiVersion。实验期只认逐字相同的。
	pluginAPIVersion = "0.1"
	// pluginSourcePrefix:插件的源名是它加清单的 id。
	pluginSourcePrefix = "plugin:"

	pluginDefaultMaxResponseBytes   = 2 << 20
	pluginMaxMaxResponseBytes       = 16 << 20
	pluginDefaultMaxRequestsPerCall = 8
	pluginMaxMaxRequestsPerCall     = 16
	pluginDefaultFetchTop           = 3
	pluginMaxFetchTop               = 5
	pluginDefaultRatePerSec         = 1.0
	pluginMinRatePerSec             = 0.05
	// pluginRateBurst:每个插件的令牌桶最多攒几次。
	pluginRateBurst = 5
	// pluginHourlyBudget:每个插件后台一小时的请求额度。
	pluginHourlyBudget = 60

	pluginManifestMaxHosts    = 32
	pluginManifestMaxTextSize = 500
)

// 清单没过校验的规则代码(pluginManifestError.Rule)。
const (
	pluginManifestRuleFileSize         = "file_size"          // 插件文件超过 512 KB
	pluginManifestRuleEncoding         = "encoding"           // 插件文件不是合法的 UTF-8
	pluginManifestRuleHeader           = "header"             // 文件开头不是清单注释,或者注释没有收尾
	pluginManifestRuleJSON             = "json"               // 清单不是一个 JSON 对象
	pluginManifestRuleID               = "id"                 // id 缺了,或者不是小写的反向域名
	pluginManifestRuleName             = "name"               // name 缺了、是空的、太长或带控制字符
	pluginManifestRuleVersion          = "version"            // version 缺了,或者不是 semver
	pluginManifestRuleAPIVersion       = "api_version"        // apiVersion 缺了,或者不是这一版引擎认的那一个
	pluginManifestRuleMinLyrimuse      = "min_lyrimuse"       // minLyrimuse 不是 semver,或者高于当前版本
	pluginManifestRuleTextField        = "text_field"         // author / homepage / description 类型不对、太长或带控制字符
	pluginManifestRuleHosts            = "hosts"              // hosts 缺了、是空的,或者某一项写法不合规
	pluginManifestRuleHostsWildcard    = "hosts_wildcard"     // 通配写法不是「*.」加至少两段的域名
	pluginManifestRuleHostsPrivatePort = "hosts_private_port" // 本机 / 内网主机没带端口
	pluginManifestRuleProvides         = "provides"           // provides 缺了、是空的,或者有不认识的取值
	pluginManifestRuleRounds           = "rounds"             // rounds 不是 all / onDemand
	pluginManifestRuleRequery          = "requery"            // requery 不是 host / self
	pluginManifestRuleExternalIDs      = "external_ids"       // externalIds 不是字符串数组
	pluginManifestRuleLimits           = "limits"             // limits 的某一项类型不对或超出许声明的范围
	pluginManifestRuleProbe            = "probe"              // probe 缺 title / artist,或者类型不对
	pluginManifestRuleUpdateURL        = "update_url"         // updateURL 不是 http(s) 地址,或者主机不在 hosts 和安装来源里
)

// 清单的警告代码(pluginManifestWarning.Rule):不拒,对应的内容当没写。
const (
	pluginManifestWarnUnknownField      = "unknown_field"       // 这一版不认识、或者还不支持的字段
	pluginManifestWarnUnknownExternalID = "unknown_external_id" // externalIds 里引擎不认识的键
	pluginManifestWarnUnknownLimit      = "unknown_limit"       // limits 里不认识的键
)

// pluginManifestError:清单没过校验。
type pluginManifestError struct {
	// Rule:没过的那一条,pluginManifestRule* 之一。
	Rule string
	// Field:清单里的哪个字段(hosts 的某一项写成 `hosts[2]`);跟具体字段无关时为空。
	Field string
	// Detail:给人看的说明。
	Detail string
}

func (e *pluginManifestError) Error() string {
	if e.Field == "" {
		return fmt.Sprintf("plugin manifest rejected (%s): %s", e.Rule, e.Detail)
	}
	return fmt.Sprintf("plugin manifest rejected (%s) at %s: %s", e.Rule, e.Field, e.Detail)
}

// pluginManifestWarning:清单里被忽略的内容。
type pluginManifestWarning struct {
	Rule, Field, Detail string
}

// pluginProvides:清单 provides 许写的取值。
var pluginProvides = []string{"word", "line", "plain", "translation", "romanization", "instrumental", "background", "duet", "songwriters"}

// pluginExternalIDKeys:清单 externalIds 许声明的平台曲目编号的键。
var pluginExternalIDKeys = []string{"appleMusic", "spotify", "youtube", "netease", "qqMusic"}

// pluginManifestFields:这一版认的清单字段。
var pluginManifestFields = []string{
	"id", "name", "version", "apiVersion", "minLyrimuse", "author", "homepage", "description", "hosts", "provides",
	"rounds", "requery", "externalIds", "limits", "probe", "updateURL",
}

var (
	pluginIDRe      = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$`)
	pluginSemverRe  = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$`)
	pluginHostLabel = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
)

// pluginLimits:清单能调的几项限额,没写的是默认值。
type pluginLimits struct {
	// MaxResponseBytes:单个应答体(解压后)的上限。
	MaxResponseBytes int
	// MaxRequestsPerCall:一次调用累计能发几个 host/fetch。
	MaxRequestsPerCall int
	// FetchTop:过闸之后取前几条去取词。
	FetchTop int
	// RatePerSec:这个插件的令牌桶每秒补几个。
	RatePerSec float64
}

// pluginProbeTrack:清单自带的探测曲。
type pluginProbeTrack struct {
	Title, Artist, Album string
	DurationSecs         float64
}

// pluginManifest 是校验过的清单。
type pluginManifest struct {
	ID, Name, Version, APIVersion              string
	MinLyrimuse, Author, Homepage, Description string
	// Hosts:网络白名单。
	Hosts pluginHostRules
	// Provides:它声明会交的内容,pluginProvides 的子集。
	Provides []string
	// OnDemand:rounds 是 onDemand(只在用户此刻在听、在找的轮次里问)。
	OnDemand bool
	// SelfRequery:requery 是 self(引擎每轮只调一次 search,不换写法)。
	SelfRequery bool
	// ExternalIDs:它声明要用的平台曲目编号的键,只留引擎认识的。
	ExternalIDs []string
	Limits      pluginLimits
	// Probe:探测曲,没写是 nil。
	Probe     *pluginProbeTrack
	UpdateURL string
	// Raw:清单 JSON 的原文,plugin/load 发给 plugin-host 的是这一份。
	Raw json.RawMessage
}

// pluginManifestOptions:校验时要跟引擎这边对的两样。
type pluginManifestOptions struct {
	// HostVersion:当前的 Lyrimuse 版本,跟 minLyrimuse 比;不是 semver(开发构建)时不比。
	HostVersion string
	// InstallHost:安装来源的主机(小写、不带端口),updateURL 的主机可以是它;本地文件安装时为空。
	InstallHost string
}

// sourceName:这个插件在缓存、留痕、统计里的源名。
func (m *pluginManifest) sourceName() string { return pluginSourcePrefix + m.ID }

func (m *pluginManifest) provides(what string) bool { return slices.Contains(m.Provides, what) }

// parsePluginFile 从插件文件全文里取出清单并校验。清单注释必须是文件里的第一样东西:`/* @lyrimuse-plugin`、一个 JSON
// 对象、`*/`。不执行文件里的任何代码。
func parsePluginFile(text []byte, opts pluginManifestOptions) (*pluginManifest, []pluginManifestWarning, error) {
	if len(text) > pluginFileMaxBytes {
		return nil, nil, &pluginManifestError{pluginManifestRuleFileSize, "", fmt.Sprintf("plugin file is %d bytes, the limit is %d", len(text), pluginFileMaxBytes)}
	}
	if !utf8.Valid(text) {
		return nil, nil, &pluginManifestError{pluginManifestRuleEncoding, "", "plugin file is not valid UTF-8"}
	}
	head := bytes.TrimLeftFunc(bytes.TrimPrefix(text, []byte("\ufeff")), unicode.IsSpace)
	if !bytes.HasPrefix(head, []byte(pluginManifestMarker)) {
		return nil, nil, &pluginManifestError{pluginManifestRuleHeader, "", "plugin file must start with the " + pluginManifestMarker + " comment"}
	}
	body := head[len(pluginManifestMarker):]
	end := bytes.Index(body, []byte("*/"))
	if end < 0 {
		return nil, nil, &pluginManifestError{pluginManifestRuleHeader, "", "manifest comment is not closed"}
	}
	return parsePluginManifest(body[:end], opts)
}

// parsePluginManifest 校验清单 JSON。返回的警告是被忽略的内容(不认识的字段、不认识的编号键),不影响安装。
func parsePluginManifest(raw []byte, opts pluginManifestOptions) (*pluginManifest, []pluginManifestWarning, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || fields == nil {
		return nil, nil, &pluginManifestError{pluginManifestRuleJSON, "", "manifest must be a JSON object"}
	}
	v := &pluginManifestValidator{fields: fields, opts: opts}
	m := &pluginManifest{Raw: json.RawMessage(bytes.TrimSpace(raw))}
	steps := []func(*pluginManifest) *pluginManifestError{
		v.identity, v.versions, v.texts, v.hosts, v.provides, v.modes, v.externalIDs, v.limits, v.probe, v.updateURL,
	}
	for _, step := range steps {
		if err := step(m); err != nil {
			return nil, nil, err
		}
	}
	for _, name := range pluginSortedKeys(fields) {
		if !slices.Contains(pluginManifestFields, name) {
			v.warn(pluginManifestWarnUnknownField, name, "not supported by this version, ignored")
		}
	}
	return m, v.warnings, nil
}

func pluginSortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// pluginManifestValidator 逐组校验清单的字段。
type pluginManifestValidator struct {
	fields   map[string]json.RawMessage
	opts     pluginManifestOptions
	warnings []pluginManifestWarning
}

func (v *pluginManifestValidator) warn(rule, field, detail string) {
	v.warnings = append(v.warnings, pluginManifestWarning{rule, field, detail})
}

// has:清单里写了这个字段(写成 null 算没写)。
func (v *pluginManifestValidator) has(name string) bool {
	raw, ok := v.fields[name]
	return ok && string(bytes.TrimSpace(raw)) != "null"
}

// text:字符串字段。没写时 ok 为真、值为空;写了但不是字符串时 ok 为假。
func (v *pluginManifestValidator) text(name string) (s string, ok bool) {
	if !v.has(name) {
		return "", true
	}
	if json.Unmarshal(v.fields[name], &s) != nil {
		return "", false
	}
	return s, true
}

func pluginTextHasControl(s string) bool {
	return strings.ContainsFunc(s, unicode.IsControl)
}

func (v *pluginManifestValidator) identity(m *pluginManifest) *pluginManifestError {
	id, ok := v.text("id")
	if !ok || len(id) > 100 || !pluginIDRe.MatchString(id) {
		return &pluginManifestError{pluginManifestRuleID, "id", "id must be a lowercase reverse-domain name such as org.example.my-source"}
	}
	name, ok := v.text("name")
	name = strings.TrimSpace(name)
	if !ok || name == "" || utf8.RuneCountInString(name) > 80 || pluginTextHasControl(name) {
		return &pluginManifestError{pluginManifestRuleName, "name", "name must be 1 to 80 characters without control characters"}
	}
	m.ID, m.Name = id, name
	return nil
}

func (v *pluginManifestValidator) versions(m *pluginManifest) *pluginManifestError {
	version, ok := v.text("version")
	if !ok || !pluginSemverRe.MatchString(version) {
		return &pluginManifestError{pluginManifestRuleVersion, "version", "version must be semver such as 1.2.0"}
	}
	api, ok := v.text("apiVersion")
	if !ok || api != pluginAPIVersion {
		return &pluginManifestError{pluginManifestRuleAPIVersion, "apiVersion",
			fmt.Sprintf("apiVersion must be the string %q, the only plugin API this Lyrimuse runs; the script says %q", pluginAPIVersion, api)}
	}
	min, ok := v.text("minLyrimuse")
	if !ok || (min != "" && !pluginSemverRe.MatchString(min)) {
		return &pluginManifestError{pluginManifestRuleMinLyrimuse, "minLyrimuse", "minLyrimuse must be semver such as 1.15.0"}
	}
	if min != "" && pluginSemverRe.MatchString(v.opts.HostVersion) && pluginSemverLess(v.opts.HostVersion, min) {
		return &pluginManifestError{pluginManifestRuleMinLyrimuse, "minLyrimuse",
			fmt.Sprintf("needs Lyrimuse %s or later, this is %s", min, v.opts.HostVersion)}
	}
	m.Version, m.APIVersion, m.MinLyrimuse = version, api, min
	return nil
}

// pluginSemverLess:a 的「主.次.修订」是不是小于 b 的。两个都要是 pluginSemverRe 认的写法;预发布、构建标识不比。
func pluginSemverLess(a, b string) bool {
	pa, pb := pluginSemverRe.FindStringSubmatch(a), pluginSemverRe.FindStringSubmatch(b)
	for i := 1; i <= 3; i++ {
		x, _ := strconv.Atoi(pa[i])
		y, _ := strconv.Atoi(pb[i])
		if x != y {
			return x < y
		}
	}
	return false
}

func (v *pluginManifestValidator) texts(m *pluginManifest) *pluginManifestError {
	for name, into := range map[string]*string{"author": &m.Author, "homepage": &m.Homepage, "description": &m.Description} {
		s, ok := v.text(name)
		if !ok || len(s) > pluginManifestMaxTextSize || pluginTextHasControl(s) {
			return &pluginManifestError{pluginManifestRuleTextField, name,
				fmt.Sprintf("%s must be a string of at most %d bytes without control characters", name, pluginManifestMaxTextSize)}
		}
		*into = strings.TrimSpace(s)
	}
	if m.Homepage != "" {
		if u, err := url.Parse(m.Homepage); err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
			return &pluginManifestError{pluginManifestRuleTextField, "homepage", "homepage must be an http(s) URL"}
		}
	}
	return nil
}

func (v *pluginManifestValidator) hosts(m *pluginManifest) *pluginManifestError {
	var list []string
	if !v.has("hosts") || json.Unmarshal(v.fields["hosts"], &list) != nil || len(list) == 0 || len(list) > pluginManifestMaxHosts {
		return &pluginManifestError{pluginManifestRuleHosts, "hosts",
			fmt.Sprintf("hosts must be an array of 1 to %d host strings", pluginManifestMaxHosts)}
	}
	for i, s := range list {
		rule, err := parsePluginHostRule(s)
		if err != nil {
			err.Field = fmt.Sprintf("hosts[%d]", i)
			return err
		}
		if !slices.Contains(m.Hosts, rule) {
			m.Hosts = append(m.Hosts, rule)
		}
	}
	return nil
}

func (v *pluginManifestValidator) provides(m *pluginManifest) *pluginManifestError {
	var list []string
	if !v.has("provides") || json.Unmarshal(v.fields["provides"], &list) != nil || len(list) == 0 {
		return &pluginManifestError{pluginManifestRuleProvides, "provides", "provides must be a non-empty array"}
	}
	for _, p := range list {
		if !slices.Contains(pluginProvides, p) {
			return &pluginManifestError{pluginManifestRuleProvides, "provides",
				fmt.Sprintf("%q is not one of %s", p, strings.Join(pluginProvides, ", "))}
		}
		if !slices.Contains(m.Provides, p) {
			m.Provides = append(m.Provides, p)
		}
	}
	return nil
}

func (v *pluginManifestValidator) modes(m *pluginManifest) *pluginManifestError {
	rounds, ok := v.text("rounds")
	if !ok || (v.has("rounds") && rounds != "all" && rounds != "onDemand") {
		return &pluginManifestError{pluginManifestRuleRounds, "rounds", `rounds must be "all" or "onDemand"`}
	}
	requery, ok := v.text("requery")
	if !ok || (v.has("requery") && requery != "host" && requery != "self") {
		return &pluginManifestError{pluginManifestRuleRequery, "requery", `requery must be "host" or "self"`}
	}
	m.OnDemand, m.SelfRequery = rounds == "onDemand", requery == "self"
	return nil
}

func (v *pluginManifestValidator) externalIDs(m *pluginManifest) *pluginManifestError {
	if !v.has("externalIds") {
		return nil
	}
	var list []string
	if json.Unmarshal(v.fields["externalIds"], &list) != nil {
		return &pluginManifestError{pluginManifestRuleExternalIDs, "externalIds", "externalIds must be an array of strings"}
	}
	for _, key := range list {
		switch {
		case !slices.Contains(pluginExternalIDKeys, key):
			v.warn(pluginManifestWarnUnknownExternalID, "externalIds", fmt.Sprintf("%q is not a known id key, ignored", key))
		case !slices.Contains(m.ExternalIDs, key):
			m.ExternalIDs = append(m.ExternalIDs, key)
		}
	}
	return nil
}

func (v *pluginManifestValidator) limits(m *pluginManifest) *pluginManifestError {
	m.Limits = pluginLimits{
		MaxResponseBytes: pluginDefaultMaxResponseBytes, MaxRequestsPerCall: pluginDefaultMaxRequestsPerCall,
		FetchTop: pluginDefaultFetchTop, RatePerSec: pluginDefaultRatePerSec,
	}
	if !v.has("limits") {
		return nil
	}
	var given map[string]json.RawMessage
	if json.Unmarshal(v.fields["limits"], &given) != nil || given == nil {
		return &pluginManifestError{pluginManifestRuleLimits, "limits", "limits must be an object"}
	}
	whole := func(name string, lo, hi int, into *int) *pluginManifestError {
		raw, ok := given[name]
		if !ok {
			return nil
		}
		var n float64
		if json.Unmarshal(raw, &n) != nil || n != math.Trunc(n) || n < float64(lo) || n > float64(hi) {
			return &pluginManifestError{pluginManifestRuleLimits, "limits." + name, fmt.Sprintf("%s must be an integer from %d to %d", name, lo, hi)}
		}
		*into = int(n)
		return nil
	}
	if err := whole("maxResponseBytes", 1, pluginMaxMaxResponseBytes, &m.Limits.MaxResponseBytes); err != nil {
		return err
	}
	if err := whole("maxRequestsPerCall", 1, pluginMaxMaxRequestsPerCall, &m.Limits.MaxRequestsPerCall); err != nil {
		return err
	}
	if err := whole("fetchTop", 1, pluginMaxFetchTop, &m.Limits.FetchTop); err != nil {
		return err
	}
	if raw, ok := given["ratePerSec"]; ok {
		var rate float64
		if json.Unmarshal(raw, &rate) != nil || rate < pluginMinRatePerSec || rate > pluginDefaultRatePerSec {
			return &pluginManifestError{pluginManifestRuleLimits, "limits.ratePerSec",
				fmt.Sprintf("ratePerSec must be a number from %g to %g", pluginMinRatePerSec, pluginDefaultRatePerSec)}
		}
		m.Limits.RatePerSec = rate
	}
	for _, name := range pluginSortedKeys(given) {
		if !slices.Contains([]string{"maxResponseBytes", "maxRequestsPerCall", "fetchTop", "ratePerSec"}, name) {
			v.warn(pluginManifestWarnUnknownLimit, "limits."+name, "not a known limit, ignored")
		}
	}
	return nil
}

func (v *pluginManifestValidator) probe(m *pluginManifest) *pluginManifestError {
	if !v.has("probe") {
		return nil
	}
	var given struct {
		Title        *string  `json:"title"`
		Artist       *string  `json:"artist"`
		Album        *string  `json:"album"`
		DurationSecs *float64 `json:"durationSecs"`
	}
	bad := &pluginManifestError{pluginManifestRuleProbe, "probe", "probe needs a non-empty title and artist; album is a string, durationSecs a non-negative number"}
	if json.Unmarshal(v.fields["probe"], &given) != nil || given.Title == nil || given.Artist == nil {
		return bad
	}
	p := &pluginProbeTrack{Title: strings.TrimSpace(*given.Title), Artist: strings.TrimSpace(*given.Artist)}
	if given.Album != nil {
		p.Album = strings.TrimSpace(*given.Album)
	}
	if given.DurationSecs != nil {
		p.DurationSecs = *given.DurationSecs
	}
	if p.Title == "" || p.Artist == "" || p.DurationSecs < 0 || pluginTextHasControl(p.Title+p.Artist+p.Album) {
		return bad
	}
	m.Probe = p
	return nil
}

func (v *pluginManifestValidator) updateURL(m *pluginManifest) *pluginManifestError {
	raw, ok := v.text("updateURL")
	if !ok {
		return &pluginManifestError{pluginManifestRuleUpdateURL, "updateURL", "updateURL must be a string"}
	}
	if raw == "" {
		return nil
	}
	u, err := url.Parse(raw)
	if err != nil || u.User != nil {
		return &pluginManifestError{pluginManifestRuleUpdateURL, "updateURL", "updateURL must be a URL without credentials"}
	}
	fromInstallHost := u.Scheme == "https" && v.opts.InstallHost != "" && strings.EqualFold(u.Hostname(), v.opts.InstallHost)
	if _, listed := m.Hosts.match(u); !listed && !fromInstallHost {
		return &pluginManifestError{pluginManifestRuleUpdateURL, "updateURL", "updateURL must point at a host in hosts or at the host the plugin was installed from"}
	}
	m.UpdateURL = raw
	return nil
}

// pluginHostRule 是清单 hosts 里的一项:许这个插件请求的一组「协议、主机、端口」。
type pluginHostRule struct {
	// Scheme:"https" 或 "http"。不写协议的是 https;明文要显式写 `http://`。
	Scheme string
	// Host:小写的主机名或 IP 字面量(IPv6 不带方括号)。通配规则存的是 `*.` 后面的那一段。
	Host string
	// Wildcard:认 Host 恰好多一层的子域,不认 Host 自己、不认更深的子域。
	Wildcard bool
	Port     int
	// Private:本机 / 内网主机(localhost、*.local、内网 IP 字面量)。这类主机必须带端口,连接时只许落到本机 / 内网地址;
	// 别的主机连接时不许落到这些地址。
	Private bool
}

// parsePluginHostRule 解析清单 hosts 的一项。
func parsePluginHostRule(s string) (pluginHostRule, *pluginManifestError) {
	bad := func(rule, detail string) (pluginHostRule, *pluginManifestError) {
		return pluginHostRule{}, &pluginManifestError{Rule: rule, Detail: fmt.Sprintf("%q: %s", s, detail)}
	}
	rest, scheme := strings.ToLower(strings.TrimSpace(s)), "https"
	if i := strings.Index(rest, "://"); i >= 0 {
		scheme, rest = rest[:i], rest[i+3:]
	}
	if scheme != "https" && scheme != "http" {
		return bad(pluginManifestRuleHosts, "only http and https are allowed")
	}
	host, port, hasPort := rest, 0, false
	switch {
	case strings.HasPrefix(rest, "["):
		end := strings.Index(rest, "]")
		if end < 0 || (end+1 < len(rest) && rest[end+1] != ':') {
			return bad(pluginManifestRuleHosts, "malformed IPv6 literal")
		}
		host = rest[1:end]
		if end+1 < len(rest) {
			hasPort = true
			rest = rest[end+1:]
		}
	case strings.Count(rest, ":") == 1:
		hasPort = true
		host, rest = rest[:strings.Index(rest, ":")], rest[strings.Index(rest, ":"):]
	case strings.Count(rest, ":") > 1:
		return bad(pluginManifestRuleHosts, "an IPv6 literal must be in brackets")
	}
	if hasPort {
		n, err := strconv.Atoi(rest[1:])
		if err != nil || n < 1 || n > 65535 {
			return bad(pluginManifestRuleHosts, "port must be 1 to 65535")
		}
		port = n
	} else if scheme == "http" {
		port = 80
	} else {
		port = 443
	}
	rule := pluginHostRule{Scheme: scheme, Host: host, Port: port}
	if strings.Contains(host, "*") {
		rule.Host, rule.Wildcard = strings.TrimPrefix(host, "*."), true
		if strings.Contains(rule.Host, "*") || (!strings.Contains(rule.Host, ".") && rule.Host != "local") {
			return bad(pluginManifestRuleHostsWildcard, "a wildcard is `*.` followed by a domain of at least two labels, and matches one extra label")
		}
	}
	if addr, err := netip.ParseAddr(rule.Host); err == nil {
		rule.Host, rule.Private = addr.Unmap().String(), pluginAddrIsLocal(addr)
	} else {
		if len(rule.Host) > 253 {
			return bad(pluginManifestRuleHosts, "host name is too long")
		}
		for _, label := range strings.Split(rule.Host, ".") {
			if !pluginHostLabel.MatchString(label) {
				return bad(pluginManifestRuleHosts, "write a host name with an optional port, without a path or credentials")
			}
		}
		rule.Private = pluginHostNameIsLocal(rule.Host)
	}
	if rule.Private && !hasPort {
		return bad(pluginManifestRuleHostsPrivatePort, "a local or private-network host must name its port")
	}
	return rule, nil
}

// pluginHostNameIsLocal:主机名按字面是不是本机 / 内网的(localhost、.localhost、.local)。host 是小写的。
func pluginHostNameIsLocal(host string) bool {
	return host == "localhost" || host == "local" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local")
}

// pluginLocalPrefixes:算作本机 / 内网的地址段。198.18.0.0/15 不在里面:代理的 fake-ip 模式把所有域名解析到这一段,
// 算进去会拒掉全部插件请求。
var pluginLocalPrefixes = func() []netip.Prefix {
	var out []netip.Prefix
	for _, s := range []string{
		"127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
		"169.254.0.0/16", "fe80::/10", "0.0.0.0/8", "::/128", "fc00::/7",
	} {
		out = append(out, netip.MustParsePrefix(s))
	}
	return out
}()

// pluginAddrIsLocal:addr 是不是本机 / 内网地址。IPv4 映射的 IPv6 地址按里面的 IPv4 判。
func pluginAddrIsLocal(addr netip.Addr) bool {
	addr = addr.Unmap()
	for _, p := range pluginLocalPrefixes {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// matches:u 的协议、主机、端口是不是这条规则许的。
func (r pluginHostRule) matches(u *url.URL) bool {
	if !strings.EqualFold(u.Scheme, r.Scheme) {
		return false
	}
	port := 443
	if r.Scheme == "http" {
		port = 80
	}
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil {
			return false
		}
		port = n
	}
	if port != r.Port {
		return false
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if addr, err := netip.ParseAddr(host); err == nil {
		host = addr.Unmap().String()
	}
	if !r.Wildcard {
		return host == r.Host
	}
	label, ok := strings.CutSuffix(host, "."+r.Host)
	return ok && label != "" && !strings.Contains(label, ".")
}

// allowsAddr:按这条规则发的请求,建立连接时能不能落到 addr。声明成本机 / 内网的只许落到本机 / 内网地址,别的反过来。
func (r pluginHostRule) allowsAddr(addr netip.Addr) bool {
	return pluginAddrIsLocal(addr) == r.Private
}

// pluginHostRules 是一份清单的网络白名单。
type pluginHostRules []pluginHostRule

// match:u 命中的那条规则。
func (rs pluginHostRules) match(u *url.URL) (pluginHostRule, bool) {
	for _, r := range rs {
		if r.matches(u) {
			return r, true
		}
	}
	return pluginHostRule{}, false
}

// descriptor 生成这个插件运行时登记用的描述符。取值都落在登记校验(admitDynamicLyricSource)许的范围里:联网源、
// 不带特权位和任何函数字段、不带主机规则;名次填非 0 只表示参加,实际名次由登记表排到内置之后。
func (m *pluginManifest) descriptor() *ProviderDescriptor {
	d := &ProviderDescriptor{
		Name: m.sourceName(), Kind: providerKindNetwork, Rounds: roundsAll,
		HourlyBudget: pluginHourlyBudget,
		// 烘在正文里的译文只摘不接:插件要交译文就放进 translation。
		Baked: bakedStripOnly,
		// 自己交背景人声轨的插件,正文里的括号是它判成主唱的部分,不再拆。
		ParenBackground:  !m.provides("background"),
		InstrumentalRank: 1, SongwritersRank: 1,
		Assembly: &CandidateAssembly{
			Reads: fieldWordTiming | fieldRomanization | fieldSourceDuration | fieldAlbum | fieldLanguage | fieldPlainText |
				fieldISRC | fieldBackground,
			Translation: translationDeclared, Instrumental: instrumentalDeclared,
		},
	}
	if m.OnDemand {
		d.Rounds = roundsOnDemand
	}
	if m.Probe != nil {
		d.Probe = &ProbeTrack{Artist: m.Probe.Artist, Title: m.Probe.Title}
	}
	return d
}

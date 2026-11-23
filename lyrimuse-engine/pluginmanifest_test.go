package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// pluginManifestSample:一份各字段都写了的合规清单(方案 4.2 的示例)。
const pluginManifestSample = `{
  "id": "org.example.lrclib-mirror",
  "name": "My LRCLIB mirror",
  "version": "1.2.0",
  "apiVersion": "0.1",
  "minLyrimuse": "1.15.0",
  "author": "example",
  "description": "Synced lyrics from my LRCLIB mirror",
  "homepage": "https://example.org/lyrics",
  "hosts": ["lrclib.example.org", "*.cdn.example.org", "http://plain.example.org", "http://localhost:8080"],
  "provides": ["line", "plain", "instrumental"],
  "rounds": "onDemand",
  "requery": "self",
  "externalIds": ["appleMusic", "spotify"],
  "limits": { "fetchTop": 5, "maxRequestsPerCall": 16, "maxResponseBytes": 16777216, "ratePerSec": 0.05 },
  "probe": { "title": "Bohemian Rhapsody", "artist": "Queen", "durationSecs": 355 },
  "updateURL": "https://lrclib.example.org/plugin.js"
}`

// patchedManifest:在 pluginManifestSample 上改几个字段。值是 nil 的键删掉。
func patchedManifest(t *testing.T, patch map[string]any) []byte {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(pluginManifestSample), &m); err != nil {
		t.Fatal(err)
	}
	for k, v := range patch {
		if v == nil {
			delete(m, k)
		} else {
			m[k] = v
		}
	}
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestPluginManifestParsesEveryField(t *testing.T) {
	m, warnings, err := parsePluginFile([]byte("\ufeff\n"+pluginManifestMarker+"\n"+pluginManifestSample+"\n*/\n\nmodule.exports = {};\n"),
		pluginManifestOptions{HostVersion: "1.15.0"})
	if err != nil || len(warnings) != 0 {
		t.Fatalf("合规的清单被拒或带了警告:%v %v", err, warnings)
	}
	want := pluginManifest{
		ID: "org.example.lrclib-mirror", Name: "My LRCLIB mirror", Version: "1.2.0", APIVersion: "0.1", MinLyrimuse: "1.15.0",
		Author: "example", Homepage: "https://example.org/lyrics", Description: "Synced lyrics from my LRCLIB mirror",
		Hosts: pluginHostRules{
			{Scheme: "https", Host: "lrclib.example.org", Port: 443},
			{Scheme: "https", Host: "cdn.example.org", Wildcard: true, Port: 443},
			{Scheme: "http", Host: "plain.example.org", Port: 80},
			{Scheme: "http", Host: "localhost", Port: 8080, Private: true},
		},
		Provides: []string{"line", "plain", "instrumental"}, OnDemand: true, SelfRequery: true,
		ExternalIDs: []string{"appleMusic", "spotify"},
		Limits:      pluginLimits{MaxResponseBytes: 16 << 20, MaxRequestsPerCall: 16, FetchTop: 5, RatePerSec: 0.05},
		Probe:       &pluginProbeTrack{Title: "Bohemian Rhapsody", Artist: "Queen", DurationSecs: 355},
		UpdateURL:   "https://lrclib.example.org/plugin.js",
	}
	got := *m
	got.Raw = nil
	if !reflect.DeepEqual(got, want) {
		t.Errorf("清单解析成\n%+v\n期望\n%+v", got, want)
	}
	var raw map[string]any
	if json.Unmarshal(m.Raw, &raw) != nil || raw["id"] != m.ID || m.sourceName() != "plugin:org.example.lrclib-mirror" {
		t.Errorf("Raw 该是清单 JSON 的原文,源名是 plugin: 加 id;得到 %s、%s", m.Raw, m.sourceName())
	}
}

// 只写必填字段:别的都是默认值。
func TestPluginManifestDefaults(t *testing.T) {
	m, _, err := parsePluginManifest([]byte(`{"id":"org.example.a","name":"A","version":"0.0.1","apiVersion":"0.1","hosts":["a.example"],"provides":["line"],"rounds":null}`),
		pluginManifestOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if m.OnDemand || m.SelfRequery || len(m.ExternalIDs) != 0 || m.Probe != nil || m.UpdateURL != "" ||
		m.Limits != (pluginLimits{MaxResponseBytes: 2 << 20, MaxRequestsPerCall: 8, FetchTop: 3, RatePerSec: 1}) {
		t.Errorf("默认值不对:%+v", m)
	}
}

// 每条规则各有只犯这一条的清单被它拒掉;声明了的规则代码一条不落。
func TestPluginManifestRules(t *testing.T) {
	long := strings.Repeat("x", 600)
	cases := []struct {
		name  string
		patch map[string]any
		opts  pluginManifestOptions
		rule  string
	}{
		{"id 缺了", map[string]any{"id": nil}, pluginManifestOptions{}, pluginManifestRuleID},
		{"id 不是字符串", map[string]any{"id": 7}, pluginManifestOptions{}, pluginManifestRuleID},
		{"id 只有一段", map[string]any{"id": "plugin"}, pluginManifestOptions{}, pluginManifestRuleID},
		{"id 带大写", map[string]any{"id": "Org.Example.A"}, pluginManifestOptions{}, pluginManifestRuleID},
		{"id 带空白", map[string]any{"id": "org.example. a"}, pluginManifestOptions{}, pluginManifestRuleID},
		{"id 带斜杠", map[string]any{"id": "org.example/../x"}, pluginManifestOptions{}, pluginManifestRuleID},
		{"id 太长", map[string]any{"id": "org.example." + strings.Repeat("a", 100)}, pluginManifestOptions{}, pluginManifestRuleID},
		{"name 缺了", map[string]any{"name": nil}, pluginManifestOptions{}, pluginManifestRuleName},
		{"name 全是空白", map[string]any{"name": "  "}, pluginManifestOptions{}, pluginManifestRuleName},
		{"name 带换行", map[string]any{"name": "a\nb"}, pluginManifestOptions{}, pluginManifestRuleName},
		{"name 太长", map[string]any{"name": strings.Repeat("名", 81)}, pluginManifestOptions{}, pluginManifestRuleName},
		{"version 缺了", map[string]any{"version": nil}, pluginManifestOptions{}, pluginManifestRuleVersion},
		{"version 不是 semver", map[string]any{"version": "1.2"}, pluginManifestOptions{}, pluginManifestRuleVersion},
		{"apiVersion 缺了", map[string]any{"apiVersion": nil}, pluginManifestOptions{}, pluginManifestRuleAPIVersion},
		{"apiVersion 是数字", map[string]any{"apiVersion": 0.1}, pluginManifestOptions{}, pluginManifestRuleAPIVersion},
		{"apiVersion 是另一个实验版本", map[string]any{"apiVersion": "0.2"}, pluginManifestOptions{}, pluginManifestRuleAPIVersion},
		{"apiVersion 是 1", map[string]any{"apiVersion": "1"}, pluginManifestOptions{}, pluginManifestRuleAPIVersion},
		{"minLyrimuse 不是 semver", map[string]any{"minLyrimuse": "latest"}, pluginManifestOptions{}, pluginManifestRuleMinLyrimuse},
		{"minLyrimuse 高于当前版本", map[string]any{"minLyrimuse": "1.15.1"}, pluginManifestOptions{HostVersion: "1.15.0"}, pluginManifestRuleMinLyrimuse},
		{"minLyrimuse 次版本高于当前", map[string]any{"minLyrimuse": "1.16.0"}, pluginManifestOptions{HostVersion: "1.15.9"}, pluginManifestRuleMinLyrimuse},
		{"author 不是字符串", map[string]any{"author": []string{"a"}}, pluginManifestOptions{}, pluginManifestRuleTextField},
		{"description 太长", map[string]any{"description": long}, pluginManifestOptions{}, pluginManifestRuleTextField},
		{"description 带控制字符", map[string]any{"description": "a\x07b"}, pluginManifestOptions{}, pluginManifestRuleTextField},
		{"homepage 不是 http(s)", map[string]any{"homepage": "javascript:alert(1)"}, pluginManifestOptions{}, pluginManifestRuleTextField},
		{"hosts 缺了", map[string]any{"hosts": nil, "updateURL": nil}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 是空的", map[string]any{"hosts": []string{}, "updateURL": nil}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 不是数组", map[string]any{"hosts": "lrclib.example.org"}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 太多", map[string]any{"hosts": slices.Repeat([]string{"a.example"}, 33)}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 带路径", map[string]any{"hosts": []string{"lrclib.example.org/api"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 带账号", map[string]any{"hosts": []string{"user@lrclib.example.org"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 是别的协议", map[string]any{"hosts": []string{"ftp://lrclib.example.org"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 端口越界", map[string]any{"hosts": []string{"lrclib.example.org:70000"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 端口不是数字", map[string]any{"hosts": []string{"lrclib.example.org:https"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 主机名不合规", map[string]any{"hosts": []string{"-bad-.example.org"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 裸的 IPv6", map[string]any{"hosts": []string{"http://fe80::1:8080"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 是空串", map[string]any{"hosts": []string{""}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 带查询串", map[string]any{"hosts": []string{"lrclib.example.org?x=1"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 端口后面带路径", map[string]any{"hosts": []string{"http://localhost:8080/api"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts IPv6 后面带路径", map[string]any{"hosts": []string{"http://[::1]/api"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts IP 带掩码", map[string]any{"hosts": []string{"http://10.0.0.0/8"}}, pluginManifestOptions{}, pluginManifestRuleHosts},
		{"hosts 星号贴着字", map[string]any{"hosts": []string{"*lrclib.example.org"}}, pluginManifestOptions{}, pluginManifestRuleHostsWildcard},
		{"hosts 写了星号", map[string]any{"hosts": []string{"*"}}, pluginManifestOptions{}, pluginManifestRuleHostsWildcard},
		{"hosts 通配整个顶级域", map[string]any{"hosts": []string{"*.org"}}, pluginManifestOptions{}, pluginManifestRuleHostsWildcard},
		{"hosts 通配在中间", map[string]any{"hosts": []string{"api.*.example.org"}}, pluginManifestOptions{}, pluginManifestRuleHostsWildcard},
		{"hosts 两层通配", map[string]any{"hosts": []string{"*.*.example.org"}}, pluginManifestOptions{}, pluginManifestRuleHostsWildcard},
		{"localhost 没带端口", map[string]any{"hosts": []string{"http://localhost"}}, pluginManifestOptions{}, pluginManifestRuleHostsPrivatePort},
		{".local 没带端口", map[string]any{"hosts": []string{"https://nas.local"}}, pluginManifestOptions{}, pluginManifestRuleHostsPrivatePort},
		{"*.local 没带端口", map[string]any{"hosts": []string{"*.local"}}, pluginManifestOptions{}, pluginManifestRuleHostsPrivatePort},
		{"内网 IP 没带端口", map[string]any{"hosts": []string{"http://192.168.1.20"}}, pluginManifestOptions{}, pluginManifestRuleHostsPrivatePort},
		{"回环 IPv6 没带端口", map[string]any{"hosts": []string{"http://[::1]"}}, pluginManifestOptions{}, pluginManifestRuleHostsPrivatePort},
		{"provides 缺了", map[string]any{"provides": nil}, pluginManifestOptions{}, pluginManifestRuleProvides},
		{"provides 是空的", map[string]any{"provides": []string{}}, pluginManifestOptions{}, pluginManifestRuleProvides},
		{"provides 有不认识的", map[string]any{"provides": []string{"line", "cover"}}, pluginManifestOptions{}, pluginManifestRuleProvides},
		{"rounds 是别的值", map[string]any{"rounds": "primaryOnly"}, pluginManifestOptions{}, pluginManifestRuleRounds},
		{"rounds 不是字符串", map[string]any{"rounds": true}, pluginManifestOptions{}, pluginManifestRuleRounds},
		{"requery 是别的值", map[string]any{"requery": "engine"}, pluginManifestOptions{}, pluginManifestRuleRequery},
		{"externalIds 不是数组", map[string]any{"externalIds": "appleMusic"}, pluginManifestOptions{}, pluginManifestRuleExternalIDs},
		{"externalIds 里不是字符串", map[string]any{"externalIds": []any{"appleMusic", 7}}, pluginManifestOptions{}, pluginManifestRuleExternalIDs},
		{"limits 不是对象", map[string]any{"limits": 3}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"fetchTop 超过 5", map[string]any{"limits": map[string]any{"fetchTop": 6}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"fetchTop 是 0", map[string]any{"limits": map[string]any{"fetchTop": 0}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"fetchTop 是小数", map[string]any{"limits": map[string]any{"fetchTop": 2.5}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"maxRequestsPerCall 超过 16", map[string]any{"limits": map[string]any{"maxRequestsPerCall": 17}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"maxRequestsPerCall 是负数", map[string]any{"limits": map[string]any{"maxRequestsPerCall": -1}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"maxRequestsPerCall 是 0", map[string]any{"limits": map[string]any{"maxRequestsPerCall": 0}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"maxResponseBytes 是 0", map[string]any{"limits": map[string]any{"maxResponseBytes": 0}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"maxResponseBytes 超过 16 MB", map[string]any{"limits": map[string]any{"maxResponseBytes": 16<<20 + 1}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"maxResponseBytes 是字符串", map[string]any{"limits": map[string]any{"maxResponseBytes": "2MB"}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"ratePerSec 调高", map[string]any{"limits": map[string]any{"ratePerSec": 2}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"ratePerSec 太低", map[string]any{"limits": map[string]any{"ratePerSec": 0.01}}, pluginManifestOptions{}, pluginManifestRuleLimits},
		{"probe 缺歌手", map[string]any{"probe": map[string]any{"title": "x"}}, pluginManifestOptions{}, pluginManifestRuleProbe},
		{"probe 歌名是空的", map[string]any{"probe": map[string]any{"title": " ", "artist": "y"}}, pluginManifestOptions{}, pluginManifestRuleProbe},
		{"probe 不是对象", map[string]any{"probe": "Queen"}, pluginManifestOptions{}, pluginManifestRuleProbe},
		{"probe 时长是负数", map[string]any{"probe": map[string]any{"title": "x", "artist": "y", "durationSecs": -1}}, pluginManifestOptions{}, pluginManifestRuleProbe},
		{"updateURL 不是字符串", map[string]any{"updateURL": 1}, pluginManifestOptions{}, pluginManifestRuleUpdateURL},
		{"updateURL 是相对地址", map[string]any{"updateURL": "/plugin.js"}, pluginManifestOptions{}, pluginManifestRuleUpdateURL},
		{"updateURL 的主机不在 hosts 里", map[string]any{"updateURL": "https://elsewhere.example/plugin.js"}, pluginManifestOptions{}, pluginManifestRuleUpdateURL},
		{"updateURL 在 hosts 里但端口不对", map[string]any{"updateURL": "https://lrclib.example.org:8443/plugin.js"}, pluginManifestOptions{}, pluginManifestRuleUpdateURL},
		{"updateURL 是安装来源主机的明文地址", map[string]any{"updateURL": "http://dl.example/plugin.js"}, pluginManifestOptions{InstallHost: "dl.example"}, pluginManifestRuleUpdateURL},
		{"updateURL 带账号", map[string]any{"updateURL": "https://u:p@lrclib.example.org/plugin.js"}, pluginManifestOptions{}, pluginManifestRuleUpdateURL},
	}
	covered := map[string]bool{}
	for _, tc := range cases {
		_, _, err := parsePluginManifest(patchedManifest(t, tc.patch), tc.opts)
		var rejected *pluginManifestError
		if !errors.As(err, &rejected) || rejected.Rule != tc.rule {
			t.Errorf("%s:期望按 %s 拒绝,得到 %v", tc.name, tc.rule, err)
			continue
		}
		if rejected.Detail == "" || !strings.Contains(rejected.Error(), tc.rule) {
			t.Errorf("%s:拒绝时要带给人看的原因和规则代码,得到 %q", tc.name, rejected.Error())
		}
		covered[tc.rule] = true
	}
	fileCases := []struct {
		name, text, rule string
	}{
		{"文件太大", pluginManifestMarker + "\n" + pluginManifestSample + "\n*/\n" + strings.Repeat("/", pluginFileMaxBytes), pluginManifestRuleFileSize},
		{"不是 UTF-8", pluginManifestMarker + "\n" + pluginManifestSample + "\n*/\n\xff", pluginManifestRuleEncoding},
		{"开头不是清单注释", "module.exports = {};\n" + pluginManifestMarker + "\n" + pluginManifestSample + "\n*/\n", pluginManifestRuleHeader},
		{"清单注释没收尾", pluginManifestMarker + "\n" + pluginManifestSample + "\n", pluginManifestRuleHeader},
		{"清单不是对象", pluginManifestMarker + "\n[1, 2]\n*/\n", pluginManifestRuleJSON},
		{"清单后面还有东西", pluginManifestMarker + "\n" + pluginManifestSample + " trailing\n*/\n", pluginManifestRuleJSON},
		{"清单是 null", pluginManifestMarker + "\nnull\n*/\n", pluginManifestRuleJSON},
	}
	for _, tc := range fileCases {
		_, _, err := parsePluginFile([]byte(tc.text), pluginManifestOptions{})
		var rejected *pluginManifestError
		if !errors.As(err, &rejected) || rejected.Rule != tc.rule {
			t.Errorf("%s:期望按 %s 拒绝,得到 %v", tc.name, tc.rule, err)
			continue
		}
		covered[tc.rule] = true
	}
	src, err := os.ReadFile("pluginmanifest.go")
	if err != nil {
		t.Fatal(err)
	}
	declared := regexp.MustCompile(`(?m)^\s*pluginManifestRule\w+\s*=\s*"([a-z_]+)"`).FindAllStringSubmatch(string(src), -1)
	if len(declared) < 15 {
		t.Fatalf("只扫到 %d 条规则代码:常量的写法变了,先修这条用例", len(declared))
	}
	for _, m := range declared {
		if !covered[m[1]] {
			t.Errorf("规则 %s 没有只犯它一条的用例", m[1])
		}
	}
}

// 规则卡在边界上:许声明的最大最小值、带端口的本机主机、安装来源主机的 updateURL、开发构建不比版本。
func TestPluginManifestAcceptsBoundaryValues(t *testing.T) {
	for name, tc := range map[string]struct {
		patch map[string]any
		opts  pluginManifestOptions
	}{
		"limits 取下限":          {map[string]any{"limits": map[string]any{"fetchTop": 1, "maxRequestsPerCall": 1, "maxResponseBytes": 1, "ratePerSec": 1}}, pluginManifestOptions{}},
		"minLyrimuse 等于当前版本":  {map[string]any{"minLyrimuse": "1.15.0"}, pluginManifestOptions{HostVersion: "1.15.0"}},
		"minLyrimuse 低于当前版本":  {map[string]any{"minLyrimuse": "1.9.9"}, pluginManifestOptions{HostVersion: "1.15.0"}},
		"开发构建不比 minLyrimuse":  {map[string]any{"minLyrimuse": "99.0.0"}, pluginManifestOptions{HostVersion: "dev"}},
		"updateURL 在安装来源的主机上": {map[string]any{"updateURL": "https://dl.example/plugin.js"}, pluginManifestOptions{InstallHost: "dl.example"}},
		"本机和内网主机带端口":          {map[string]any{"hosts": []string{"lrclib.example.org", "http://127.0.0.1:8080", "https://nas.local:8443", "http://[::1]:9000", "*.local:8080", "http://10.0.0.2:80"}}, pluginManifestOptions{}},
		"id 最长 100":           {map[string]any{"id": "org." + strings.Repeat("a", 96)}, pluginManifestOptions{}},
		"name 最长 80":          {map[string]any{"name": strings.Repeat("名", 80)}, pluginManifestOptions{}},
		"hosts 最多 32 项":       {map[string]any{"hosts": append(slices.Repeat([]string{"a.example"}, 31), "lrclib.example.org")}, pluginManifestOptions{}},
		"可选的文本都不写":            {map[string]any{"author": nil, "homepage": nil, "description": nil, "minLyrimuse": nil, "probe": nil}, pluginManifestOptions{}},
	} {
		if _, _, err := parsePluginManifest(patchedManifest(t, tc.patch), tc.opts); err != nil {
			t.Errorf("%s:不该被拒,得到 %v", name, err)
		}
	}
}

// 不认识的字段、编号键、限额键不拒,当没写,各给一条警告。
func TestPluginManifestWarnsAboutIgnoredContent(t *testing.T) {
	m, warnings, err := parsePluginManifest(patchedManifest(t, map[string]any{
		"settings": []any{}, "publicKey": "abc", "x-vendor": 1,
		"externalIds": []string{"spotify", "kkbox", "spotify"},
		"limits":      map[string]any{"fetchTop": 2, "maxHeapBytes": 1},
	}), pluginManifestOptions{})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, w := range warnings {
		got = append(got, w.Rule+" "+w.Field)
	}
	want := []string{
		"unknown_external_id externalIds", "unknown_limit limits.maxHeapBytes",
		"unknown_field publicKey", "unknown_field settings", "unknown_field x-vendor",
	}
	if !slices.Equal(got, want) || !slices.Equal(m.ExternalIDs, []string{"spotify"}) || m.Limits.FetchTop != 2 {
		t.Errorf("警告 %v\n期望 %v;externalIds %v、fetchTop %d", got, want, m.ExternalIDs, m.Limits.FetchTop)
	}
}

func TestPluginHostRuleMatching(t *testing.T) {
	rules := pluginHostRules{}
	for _, s := range []string{
		"lrclib.example.org", "*.cdn.example.org", "http://plain.example.org", "api.example.org:8443",
		"http://localhost:8080", "http://192.168.1.20:8080", "http://[::1]:9000", "LRCLIB.Example.NET",
	} {
		rule, err := parsePluginHostRule(s)
		if err != nil {
			t.Fatalf("%s 该是合规的写法:%v", s, err)
		}
		rules = append(rules, rule)
	}
	for raw, want := range map[string]bool{
		"https://lrclib.example.org/api/get?x=1":   true,
		"https://LRCLIB.example.org./api":          true,
		"https://lrclib.example.org:443/api":       true,
		"http://lrclib.example.org/api":            false, // 没声明明文
		"https://lrclib.example.org:8443/api":      false, // 端口不对
		"https://sub.lrclib.example.org/":          false, // 没声明通配
		"https://evil-lrclib.example.org/":         false,
		"https://lrclib.example.org.evil.test/":    false,
		"https://a.cdn.example.org/x":              true,
		"https://cdn.example.org/x":                false, // 通配不认自己
		"https://a.b.cdn.example.org/x":            false, // 只认多一层
		"https://xcdn.example.org/x":               false,
		"http://plain.example.org/x":               true,
		"https://plain.example.org/x":              false, // 声明的是明文那一个
		"http://plain.example.org:8080/x":          false,
		"https://api.example.org:8443/x":           true,
		"https://api.example.org/x":                false,
		"http://localhost:8080/x":                  true,
		"http://localhost/x":                       false,
		"http://127.0.0.1:8080/x":                  false, // 声明的是 localhost 这个名字
		"http://192.168.1.20:8080/x":               true,
		"http://192.168.1.21:8080/x":               false,
		"http://[::1]:9000/x":                      true,
		"http://[::ffff:192.168.1.20]:8080/x":      true, // IPv4 映射的写法按里面的 IPv4 认
		"https://lrclib.example.net/x":             true,
		"ftp://lrclib.example.org/x":               false,
		"https://user@lrclib.example.org:bad/x":    false,
		"https://not-declared.example/x":           false,
		"https://lrclib.example.org@evil.test/x":   false,
		"https://evil.test/https://lrclib.example": false,
	} {
		u, err := url.Parse(raw)
		if err != nil {
			if want {
				t.Errorf("%s 解析不了", raw)
			}
			continue
		}
		if _, got := rules.match(u); got != want {
			t.Errorf("%s 命中白名单 = %v,期望 %v", raw, got, want)
		}
	}
}

// 本机 / 内网地址段写死;198.18.0.0/15(代理的 fake-ip 段)不算。声明成公网的主机不许落到这些地址,本机 / 内网的反过来。
func TestPluginLocalAddressRanges(t *testing.T) {
	for raw, want := range map[string]bool{
		"127.0.0.1": true, "127.255.255.254": true, "::1": true, "10.1.2.3": true, "172.16.0.1": true, "172.31.255.255": true,
		"172.32.0.1": false, "172.15.255.255": false, "192.168.0.1": true, "192.169.0.1": false, "169.254.1.1": true,
		"fe80::1": true, "0.0.0.0": true, "0.1.2.3": true, "::": true, "fc00::1": true, "fdff::1": true, "fe00::1": false,
		"::ffff:127.0.0.1": true, "::ffff:10.0.0.1": true, "::ffff:8.8.8.8": false,
		"198.18.0.1": false, "198.19.255.255": false, "8.8.8.8": false, "1.1.1.1": false, "2606:4700::1111": false, "11.0.0.1": false,
	} {
		if got := pluginAddrIsLocal(netip.MustParseAddr(raw)); got != want {
			t.Errorf("%s 算本机 / 内网 = %v,期望 %v", raw, got, want)
		}
	}
	public, _ := parsePluginHostRule("lrclib.example.org")
	private, _ := parsePluginHostRule("http://localhost:8080")
	for _, tc := range []struct {
		rule pluginHostRule
		addr string
		want bool
	}{
		{public, "93.184.216.34", true}, {public, "127.0.0.1", false}, {public, "192.168.1.5", false}, {public, "198.18.0.7", true},
		{private, "127.0.0.1", true}, {private, "::1", true}, {private, "93.184.216.34", false},
	} {
		if got := tc.rule.allowsAddr(netip.MustParseAddr(tc.addr)); got != tc.want {
			t.Errorf("规则 %+v 连到 %s = %v,期望 %v", tc.rule, tc.addr, got, tc.want)
		}
	}
}

// manifestStubProvider:拿清单生成的描述符去登记的假实现,会探测。
type manifestStubProvider struct{ desc *ProviderDescriptor }

func (p manifestStubProvider) Descriptor() *ProviderDescriptor { return p.desc }
func (p manifestStubProvider) Resolve(context.Context, ProviderQuery, RoundEnv) SourceResult {
	return SourceResult{}
}
func (p manifestStubProvider) ProbeOwnTrack(context.Context) bool { return false }

// 清单生成的描述符落在登记校验许的范围里,各字段照清单和固定值填。
func TestPluginManifestDescriptorPassesRegistration(t *testing.T) {
	full, _, err := parsePluginManifest([]byte(pluginManifestSample), pluginManifestOptions{})
	if err != nil {
		t.Fatal(err)
	}
	minimal, _, err := parsePluginManifest([]byte(`{"id":"org.example.b","name":"B","version":"0.0.1","apiVersion":"0.1","hosts":["b.example"],"provides":["word","background"]}`),
		pluginManifestOptions{})
	if err != nil {
		t.Fatal(err)
	}
	useDynamicLyricProviders(t, manifestStubProvider{full.descriptor()}, manifestStubProvider{minimal.descriptor()})

	reads := fieldWordTiming | fieldRomanization | fieldSourceDuration | fieldAlbum | fieldLanguage | fieldPlainText | fieldISRC | fieldBackground
	wantFull := ProviderDescriptor{
		Name: "plugin:org.example.lrclib-mirror", Kind: providerKindNetwork, Rounds: roundsOnDemand, HourlyBudget: 60,
		Baked: bakedStripOnly, ParenBackground: true, InstrumentalRank: 1, SongwritersRank: 1,
		Assembly: &CandidateAssembly{Reads: reads, Translation: translationDeclared, Instrumental: instrumentalDeclared},
		Probe:    &ProbeTrack{Artist: "Queen", Title: "Bohemian Rhapsody"},
	}
	wantMinimal := wantFull
	wantMinimal.Name, wantMinimal.Rounds, wantMinimal.ParenBackground, wantMinimal.Probe = "plugin:org.example.b", roundsAll, false, nil
	for _, tc := range []struct {
		m    *pluginManifest
		want ProviderDescriptor
	}{{full, wantFull}, {minimal, wantMinimal}} {
		if got := *tc.m.descriptor(); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s 的描述符\n%+v\n期望\n%+v", tc.m.ID, got, tc.want)
		}
		registered := lyricProviders().descriptor(tc.m.sourceName())
		if registered == nil || registered.Origin != originDynamic || registered.Privileges != 0 || len(registered.Hosts) != 0 {
			t.Errorf("%s 登记之后该是不带特权、不带主机规则的运行时来源,得到 %+v", tc.m.ID, registered)
		}
	}
}

// 一致性用例目录里的夹具清单、能拿来测引擎的用例的插件文件(清单连同各用例盖在上面的几个键)都过得了清单校验。
func TestPluginProtocolFixtureManifestsAreValid(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join(ppDir, "manifests", "*.json"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("没找到夹具清单: %v", err)
	}
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, warnings, err := parsePluginManifest(raw, pluginManifestOptions{}); err != nil || len(warnings) != 0 {
			t.Errorf("%s:%v %v", path, err, warnings)
		}
	}
	for _, c := range ppLoadCases(t) {
		// 只测 plugin-host 的用例里,清单可以是引擎本来就不会放行的(故意写错的 apiVersion)。
		if !c.subjectIncludes(ppEngine) {
			continue
		}
		if _, warnings, err := parsePluginFile([]byte(c.values.source), pluginManifestOptions{}); err != nil || len(warnings) != 0 {
			t.Errorf("用例 %s 的插件文件:%v %v", c.ID, err, warnings)
		}
	}
}

package main

import (
	"net"
	"testing"
	"time"
)

// scutilProxySample 是 2026-09-03 在这台机器上 `scutil --proxy` 的真实输出(Clash Verge
// 开着系统代理时),原样留档 —— 解析器的每一条断言都对着这份真样本,不是照着我以为的格式写的。
const scutilProxySample = `<dictionary> {
  ExceptionsList : <array> {
    0 : 127.0.0.1
    1 : 192.168.0.0/16
    2 : 10.0.0.0/8
    3 : localhost
    4 : *.local
    5 : <local>
  }
  FTPPassive : 1
  HTTPEnable : 1
  HTTPPort : 7897
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7897
  HTTPSProxy : 127.0.0.1
  ProxyAutoConfigEnable : 0
  SOCKSEnable : 1
  SOCKSPort : 7897
  SOCKSProxy : 127.0.0.1
}`

func TestParseSCUtilProxyRealSample(t *testing.T) {
	u := parseSCUtilProxy(scutilProxySample)
	if u == nil {
		t.Fatal("真实样本应该解析出代理,得到 nil")
	}
	if u.Host != "127.0.0.1:7897" {
		t.Errorf("Host = %q, 期望 127.0.0.1:7897", u.Host)
	}
	// ⚠️ 这一条是这个解析器最容易写错的地方:HTTPSProxy 说的是"给 https 流量用的代理",
	// 不是"用 https 连代理"。写成 https:// 会让 Go 先去跟本机 Clash 做一次 TLS,而那个
	// 端口不说 TLS,整条兜底路径直接握手失败 —— 而且失败得很像"代理本身坏了"。
	if u.Scheme != "http" {
		t.Errorf("Scheme = %q, 期望 http(HTTP CONNECT 代理,不是 https)", u.Scheme)
	}
}

func TestParseSCUtilProxyPriorityAndFallbacks(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string // "" = 期望 nil
		sch  string
	}{
		{
			name: "只开 HTTP,没开 HTTPS",
			in:   "<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 1087\n  HTTPProxy : 10.1.2.3\n  HTTPSEnable : 0\n}",
			want: "10.1.2.3:1087", sch: "http",
		},
		{
			name: "只开 SOCKS",
			in:   "<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n  SOCKSEnable : 1\n  SOCKSPort : 1080\n  SOCKSProxy : 127.0.0.1\n}",
			want: "127.0.0.1:1080", sch: "socks5",
		},
		{
			name: "HTTPS 优先于 HTTP 和 SOCKS",
			in: "<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 1\n  HTTPProxy : 1.1.1.1\n" +
				"  HTTPSEnable : 1\n  HTTPSPort : 2\n  HTTPSProxy : 2.2.2.2\n" +
				"  SOCKSEnable : 1\n  SOCKSPort : 3\n  SOCKSProxy : 3.3.3.3\n}",
			want: "2.2.2.2:2", sch: "http",
		},
		{
			name: "全关",
			in:   "<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n  SOCKSEnable : 0\n}",
			want: "",
		},
		{
			name: "空输出",
			in:   "",
			want: "",
		},
		{
			// PAC 刻意不支持:算不出用哪个代理就不猜,退回直连。
			name: "只有 PAC",
			in:   "<dictionary> {\n  ProxyAutoConfigEnable : 1\n  ProxyAutoConfigURLString : http://x/y.pac\n}",
			want: "",
		},
		{
			name: "开着但端口非法",
			in:   "<dictionary> {\n  HTTPSEnable : 1\n  HTTPSPort : 0\n  HTTPSProxy : 127.0.0.1\n}",
			want: "",
		},
		{
			name: "开着但没有主机",
			in:   "<dictionary> {\n  HTTPSEnable : 1\n  HTTPSPort : 7897\n}",
			want: "",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := parseSCUtilProxy(c.in)
			if c.want == "" {
				if u != nil {
					t.Fatalf("期望 nil, 得到 %v", u)
				}
				return
			}
			if u == nil {
				t.Fatalf("期望 %s, 得到 nil", c.want)
			}
			if u.Host != c.want || u.Scheme != c.sch {
				t.Errorf("得到 %s://%s, 期望 %s://%s", u.Scheme, u.Host, c.sch, c.want)
			}
		})
	}
}

// ExceptionsList 里那些 `0 : 127.0.0.1` 形状的行,键是纯数字,不能污染 HTTPSProxy 这些
// 真键 —— 解析器故意不做括号配对,靠的就是这个前提,钉住它。
func TestParseSCUtilProxyIgnoresExceptionsListRows(t *testing.T) {
	in := "<dictionary> {\n  ExceptionsList : <array> {\n    0 : 127.0.0.1\n" +
		"    1 : HTTPSProxy\n  }\n  HTTPSEnable : 1\n  HTTPSPort : 7897\n  HTTPSProxy : 9.9.9.9\n}"
	u := parseSCUtilProxy(in)
	if u == nil || u.Host != "9.9.9.9:7897" {
		t.Fatalf("得到 %v, 期望 9.9.9.9:7897", u)
	}
}

func TestEnvProxyURLBareHostGetsHTTPScheme(t *testing.T) {
	// curl / Clash 生态里裸写 host:port 是常见写法,neturl.Parse 对它会把 host 当 scheme。
	t.Setenv("HTTPS_PROXY", "127.0.0.1:7897")
	u := envProxyURL()
	if u == nil || u.Scheme != "http" || u.Host != "127.0.0.1:7897" {
		t.Fatalf("得到 %v, 期望 http://127.0.0.1:7897", u)
	}
}

// 环境变量优先于系统设置(readSystemProxyURL 的第一步)——从终端手动跑 collector 子命令时
// 显式指定的意图不该被系统设置盖掉。
func TestReadSystemProxyPrefersEnv(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:65001")
	u := readSystemProxyURL()
	if u == nil || u.Host != "127.0.0.1:65001" {
		t.Fatalf("得到 %v, 期望环境变量里那个", u)
	}
}

// systemProxyURL 的探活闸:配置着但连不上的代理必须当作"没有代理",否则本来只是某个源
// 直连不通,会升级成"兜底通道也是死的、还要白等一次超时"。
func TestSystemProxyURLRejectsUnreachable(t *testing.T) {
	resetSystemProxyCacheForTest()
	defer resetSystemProxyCacheForTest()

	// 先占一个端口拿到"肯定没人监听"的号码,再放掉。
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := ln.Addr().String()
	ln.Close()

	t.Setenv("HTTPS_PROXY", "http://"+dead)
	if u := systemProxyURL(); u != nil {
		t.Fatalf("连不上的代理应判 nil, 得到 %v", u)
	}

	// 换成真的听着的端口,同一套路径要认。
	live, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close()
	resetSystemProxyCacheForTest()
	t.Setenv("HTTPS_PROXY", "http://"+live.Addr().String())
	u := systemProxyURL()
	if u == nil || u.Host != live.Addr().String() {
		t.Fatalf("连得上的代理应被采纳, 得到 %v", u)
	}

	// 缓存生效:同一个 TTL 窗口内不重读(把环境变量换掉也不该立刻变)。
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	if u2 := systemProxyURL(); u2 == nil || u2.Host != live.Addr().String() {
		t.Fatalf("TTL 内应命中缓存, 得到 %v", u2)
	}
}

func resetSystemProxyCacheForTest() {
	systemProxyMu.Lock()
	systemProxyValue, systemProxyReadAt = nil, time.Time{}
	systemProxyMu.Unlock()
}

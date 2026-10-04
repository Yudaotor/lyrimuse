package main

import "testing"

// DoH 响应里 A 记录之外的东西不能当地址用。真实响应里 CNAME(type 5) 很常见 ——
// apic-*.musixmatch.com 就是 CNAME 到 AWS 的域名，把 CNAME 的 data 当 IP 去拨号
// 会直接失败，而失败之后代码会静默退回系统 DNS，也就是退回这个 bug 本身。
func TestDoHParseAnswerKeepsOnlyARecords(t *testing.T) {
	body := []byte(`{"Status":0,"Answer":[
		{"name":"apic-appmobile.musixmatch.com","type":5,"TTL":300,"data":"elb.amazonaws.com."},
		{"name":"elb.amazonaws.com","type":1,"TTL":60,"data":"44.212.146.46"},
		{"name":"elb.amazonaws.com","type":1,"TTL":60,"data":"52.5.55.223"}
	]}`)
	got := dohParseAnswer(body)
	if len(got) != 2 || got[0] != "44.212.146.46" || got[1] != "52.5.55.223" {
		t.Fatalf("只该留下两条 A 记录, got %v", got)
	}
}

// AAAA(type 28)也要挡掉：这套拨号器拼的是 host:port，IPv6 地址得加方括号，
// 直接塞进去会拼出一个非法地址。
func TestDoHParseAnswerRejectsNonIPv4(t *testing.T) {
	body := []byte(`{"Answer":[
		{"type":28,"data":"2606:4700::6810:d76"},
		{"type":1,"data":"1.2.3.4"},
		{"type":1,"data":"不是地址"}
	]}`)
	got := dohParseAnswer(body)
	if len(got) != 1 || got[0] != "1.2.3.4" {
		t.Fatalf("只该留下合法的 IPv4, got %v", got)
	}
}

func TestDoHParseAnswerHandlesGarbage(t *testing.T) {
	for _, body := range []string{"", "{}", "not json", `{"Answer":[]}`, `{"Answer":null}`} {
		if got := dohParseAnswer([]byte(body)); len(got) != 0 {
			t.Errorf("%q 应该返回空, got %v", body, got)
		}
	}
}

// 只有清单里的域名走 DoH。别的域名一律走系统解析 —— 把整个进程的 DNS 行为改掉，
// 影响面远超这个 bug 需要修的范围。
func TestDoHShouldResolveOnlyListedHosts(t *testing.T) {
	yes := []string{
		"apic-appmobile.musixmatch.com",
		"apic-desktop.musixmatch.com",
		"APIC-DESKTOP.MUSIXMATCH.COM",  // 大小写不敏感
		"apic-desktop.musixmatch.com.", // 末尾的根点
	}
	for _, h := range yes {
		if !dohShouldResolve(h) {
			t.Errorf("%q 应该走 DoH", h)
		}
	}
	no := []string{
		"music.163.com",
		"lrclib.net",
		"c.y.qq.com",
		"",
		// 后缀匹配必须以 "." 打头，否则这种冒名域名会被误判成自己人。
		"evil-musixmatch.com",
		"musixmatch.com.attacker.example",
	}
	for _, h := range no {
		if dohShouldResolve(h) {
			t.Errorf("%q 不该走 DoH", h)
		}
	}
}

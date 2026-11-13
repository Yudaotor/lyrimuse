package main

import "testing"

// DoH 响应里 A 记录之外的东西不能当地址用。真实响应里 CNAME(type 5) 很常见,
// 把 CNAME 的 data 当 IP 去拨号会直接失败,而失败之后代码会静默退回系统 DNS。
func TestDoHParseAnswerKeepsOnlyARecords(t *testing.T) {
	body := []byte(`{"Status":0,"Answer":[
		{"name":"lyrics.example.com","type":5,"TTL":300,"data":"elb.amazonaws.com."},
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

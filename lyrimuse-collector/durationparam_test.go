package main

import "testing"

// 2026-08-30:活路径(scrobble / updateNowPlaying)此前**不发** duration,而 backfill.go
// 一直在发 —— 同一首歌当场提交反而比事后回填少一个字段。这一组钉的是补上之后的口径:
// 只发正数、整数秒、拿不到就整个键不发(发 0 比不发更糟,那是在断言"这首歌长度为零")。
func TestDurationParam(t *testing.T) {
	cases := []struct {
		name string
		secs float64
		want string // "" = 不该出现这个键
	}{
		{"正常曲长取整数秒", 322.018, "322"},
		{"向下取整,不四舍五入(跟 backfill 的 int64() 转换逐字一致)", 208.9, "208"},
		{"拿不到曲长(0)不发这个键", 0, ""},
		{"负数不发(异常值,发出去等于断言了一个假事实)", -5, ""},
		{"刚好 1 秒仍然发", 1, "1"},
	}
	for _, c := range cases {
		p := map[string]string{}
		durationParam(p, "duration", c.secs)
		got, ok := p["duration"]
		if c.want == "" {
			if ok {
				t.Errorf("%s: 不该有 duration 键, got %q", c.name, got)
			}
			continue
		}
		if got != c.want {
			t.Errorf("%s: duration = %q, want %q", c.name, got, c.want)
		}
	}
}

// 批量键名带下标(duration[0]),同一个 helper 要能用 —— 免得回填那边以后想复用时
// 发现只支持固定键名，又抄一份出去。
func TestDurationParamHonorsKeyName(t *testing.T) {
	p := map[string]string{}
	durationParam(p, "duration[3]", 180)
	if p["duration[3]"] != "180" {
		t.Fatalf("带下标的键名没生效: %+v", p)
	}
	if _, ok := p["duration"]; ok {
		t.Fatal("不该顺手写一个裸 duration 键")
	}
}

package main

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

// qqSpokenTick:QQ 音乐在放的一拍;verdict 为 nil = App 还没判出来是不是有声节目。
func qqSpokenTick(title string, pos float64, at time.Time, verdict *bool) snapshot {
	s := snapshot{Title: title, Artist: "茂桐笙花", Album: "一听就上瘾的通史", Bundle: qqMusicBundleID, Duration: 261,
		Playing: true, Rate: 1, Position: pos, AnchorTS: at}
	if verdict == nil {
		s.SpokenPending = true
	} else {
		s.Spoken = *verdict
	}
	return s
}

func TestAppStateSnapshotCarriesSpokenVerdict(t *testing.T) {
	parse := func(player, track string) snapshot {
		var rec appStateRecord
		raw := `{"player":"` + player + `","state":"playing","track":{"play_seq":1,"title":"a","artist":"b","album":"c"` + track + `}}`
		if err := json.Unmarshal([]byte(raw), &rec); err != nil {
			t.Fatal(err)
		}
		return appStateSnapshot(rec, time.Now())
	}
	if s := parse(qqMusicBundleID, `,"spoken":true`); !s.Spoken || s.SpokenPending {
		t.Fatalf("QQ 报了有声节目: %+v", s)
	}
	if s := parse(qqMusicBundleID, `,"spoken":false`); s.Spoken || s.SpokenPending {
		t.Fatalf("QQ 报了不是: %+v", s)
	}
	if s := parse(qqMusicBundleID, ``); s.Spoken || !s.SpokenPending {
		t.Fatalf("QQ 没有这个键 = 还在判: %+v", s)
	}
	if s := parse("com.apple.Music", ``); s.Spoken || s.SpokenPending {
		t.Fatalf("别的播放器没有这个键不等: %+v", s)
	}
}

func TestAwaitsSpokenVerdictHasALimit(t *testing.T) {
	t0 := time.Now()
	pending := snapshot{SpokenPending: true}
	if !awaitsSpokenVerdict(pending, t0, t0.Add(time.Second)) {
		t.Fatal("开播 1 秒、还没结论 → 等")
	}
	if awaitsSpokenVerdict(pending, t0, t0.Add(spokenVerdictWait)) {
		t.Fatal("等到上限就不等了")
	}
	if awaitsSpokenVerdict(snapshot{}, t0, t0) {
		t.Fatal("有结论 / 不是 QQ 不等")
	}
}

// 有声节目:不宣布正在播放、过线不提交、网页中继不推;字幕照常解析(这里只查缓存,不起后台解析)。
func TestHandleSpokenAudioIsNotASong(t *testing.T) {
	at := handleClock()
	yes := true
	a := qqSpokenTick("通史-000引言", 0, at(0), &yes)
	p := handleTestPoller(t, a)
	for s := 0; s <= 200; s += 10 {
		handleTick(p, at(s), qqSpokenTick("通史-000引言", float64(s), at(s), &yes))
	}
	if !p.sess.isSpoken || p.sess.announcing || !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("有声节目不当歌: spoken=%v announcing=%v sent=%v inflight=%d",
			p.sess.isSpoken, p.sess.announcing, p.sess.listenSent, len(p.submitsInflight))
	}
}

// 开播时结论还没到:正在播放先挂起、预取挪后;结论到了是歌就照常宣布;中途才判出是有声节目的,之后不提交。
func TestHandleWaitsForSpokenVerdict(t *testing.T) {
	at := handleClock()
	a := qqSpokenTick("通史-000引言", 0, at(0), nil)
	p := handleTestPoller(t, a)
	handleTick(p, at(0), a)
	if !p.sess.pnPending || !p.sess.prefetchDeferred || p.sess.announcing {
		t.Fatalf("等结论: pending=%v deferred=%v announcing=%v", p.sess.pnPending, p.sess.prefetchDeferred, p.sess.announcing)
	}
	yes := true
	handleTick(p, at(1), qqSpokenTick("通史-000引言", 1, at(1), &yes))
	if !p.sess.isSpoken || p.sess.prefetchDeferred || p.sess.announcing {
		t.Fatalf("判成有声节目: spoken=%v deferred=%v announcing=%v", p.sess.isSpoken, p.sess.prefetchDeferred, p.sess.announcing)
	}

	b := qqSpokenTick("晴天", 0, at(0), nil)
	q := handleTestPoller(t, b)
	handleTick(q, at(0), b)
	for s := 1; s <= 2; s++ {
		handleTick(q, at(s), qqSpokenTick("晴天", float64(s), at(s), nil))
	}
	if !q.sess.prefetchDeferred {
		t.Fatal("上限之内还在等")
	}
	handleTick(q, at(5), qqSpokenTick("晴天", 5, at(5), nil))
	if q.sess.prefetchDeferred || q.sess.isSpoken {
		t.Fatalf("等到上限照常当歌: deferred=%v spoken=%v", q.sess.prefetchDeferred, q.sess.isSpoken)
	}
}

// QQ 的结论还没到时网页中继不推(推出去的可能就是这一集有声节目);到了上限照常走推送的判定
// (这首没封面,判定那一步记下 relayDeferKey、先等封面)。
func TestPushRelayStateWaitsForSpokenVerdict(t *testing.T) {
	t0 := time.Now()
	cur := qqSpokenTick("通史-000引言", 0, t0, nil)
	p := &poller{ctx: context.Background(), cfg: &config{StateRelayURL: "http://127.0.0.1:9"}, relayDoneCh: make(chan relayPushResult, 1),
		cur: cur, sess: &playSession{key: cur.key(), startedAt: t0}}
	p.pushRelayState(t0.Add(time.Second), false)
	if p.relayInflight || p.relayDeferKey != "" {
		t.Fatalf("还在等 QQ 的结论,不该走到推送: inflight=%v defer=%q", p.relayInflight, p.relayDeferKey)
	}
	p.pushRelayState(t0.Add(spokenVerdictWait), false)
	if p.relayDeferKey == "" {
		t.Fatal("等到上限照常走推送的判定")
	}
}

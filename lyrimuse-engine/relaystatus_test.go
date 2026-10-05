package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func useRelayStatusPathForTest(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "relay-status.json")
	relayStatusMu.Lock()
	old := relayStatusPath
	relayStatusPath = path
	relayStatusMu.Unlock()
	t.Cleanup(func() {
		relayStatusMu.Lock()
		relayStatusPath = old
		relayStatusMu.Unlock()
	})
	return path
}

func readRelayStatusForTest(t *testing.T, path string) (relayStatusFile, bool) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return relayStatusFile{}, false
	}
	if err != nil {
		t.Fatal(err)
	}
	var f relayStatusFile
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	return f, true
}

func TestRelayFailureKind(t *testing.T) {
	cases := []struct {
		err    error
		kind   string
		status int
	}{
		{&relayHTTPError{path: "/push", status: 401}, relayFailAuth, 401},
		{&relayHTTPError{path: "/push", status: 403}, relayFailAuth, 403},
		{&relayHTTPError{path: "/push", status: 404}, relayFailNotFound, 404},
		{&relayHTTPError{path: "/push", status: 405}, relayFailNotFound, 405},
		{&relayHTTPError{path: "/push", status: 400}, relayFailRejected, 400},
		{&relayHTTPError{path: "/push", status: 413}, relayFailRejected, 413},
		{&relayHTTPError{path: "/push", status: 408}, relayFailServer, 408},
		{&relayHTTPError{path: "/push", status: 429}, relayFailServer, 429},
		{&relayHTTPError{path: "/push", status: 503}, relayFailServer, 503},
		{fmt.Errorf("wrapped: %w", &relayHTTPError{path: "/push", status: 401}), relayFailAuth, 401},
		{errors.New("dial tcp: i/o timeout"), relayFailNetwork, 0},
	}
	for _, c := range cases {
		if kind, status := relayFailureKind(c.err); kind != c.kind || status != c.status {
			t.Errorf("%v: got %s/%d, want %s/%d", c.err, kind, status, c.kind, c.status)
		}
	}
}

// 推不出去写状态文件:同一类失败不重写,since 是这一串的头一次;推成功删掉;下一串从头算。
func TestApplyRelayResultReportsHealth(t *testing.T) {
	path := useRelayStatusPathForTest(t)
	t0 := time.Unix(1_800_000_000, 0)
	p := &poller{relayInflight: true}
	p.applyRelayResult(relayPushResult{key: "mac|a", at: t0, err: &relayHTTPError{path: "/push", status: 401}})
	want := relayStatusFile{Schema: relayStatusSchema, Kind: relayFailAuth, Status: 401, Since: t0.Unix()}
	if f, ok := readRelayStatusForTest(t, path); !ok || f != want {
		t.Fatalf("令牌被拒要报: %+v ok=%v", f, ok)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	p.applyRelayResult(relayPushResult{key: "mac|a", at: t0.Add(time.Minute), err: &relayHTTPError{path: "/push", status: 401}})
	if _, ok := readRelayStatusForTest(t, path); ok {
		t.Fatal("同一类失败不重写")
	}
	p.applyRelayResult(relayPushResult{key: "mac|a", at: t0.Add(2 * time.Minute), err: errors.New("dial tcp: i/o timeout")})
	want = relayStatusFile{Schema: relayStatusSchema, Kind: relayFailNetwork, Since: t0.Unix()}
	if f, ok := readRelayStatusForTest(t, path); !ok || f != want {
		t.Fatalf("换了一类失败要重写,since 仍是这一串的头一次: %+v ok=%v", f, ok)
	}
	p.applyRelayResult(relayPushResult{key: "mac|a", at: t0.Add(3 * time.Minute)})
	if _, ok := readRelayStatusForTest(t, path); ok {
		t.Fatal("推成功要删状态文件")
	}
	p.applyRelayResult(relayPushResult{key: "mac|b", at: t0.Add(4 * time.Minute), err: &relayHTTPError{path: "/push", status: 503}})
	if f, _ := readRelayStatusForTest(t, path); f.Since != t0.Add(4*time.Minute).Unix() || f.Kind != relayFailServer {
		t.Fatalf("下一串失败从头算: %+v", f)
	}
}

// 主动取消(引擎退出)不算推送失败。
func TestApplyRelayResultIgnoresCancellation(t *testing.T) {
	path := useRelayStatusPathForTest(t)
	p := &poller{relayInflight: true}
	p.applyRelayResult(relayPushResult{key: "mac|a", at: time.Now(), err: fmt.Errorf("post: %w", context.Canceled)})
	if _, ok := readRelayStatusForTest(t, path); ok || !p.relayFailingSince.IsZero() {
		t.Fatal("取消不该报失败")
	}
}

// 中继地址或令牌在推送飞着的时候改了:回来的结果说的是旧配置,不记账、不报状态。
func TestApplyRelayResultIgnoresOldConfig(t *testing.T) {
	path := useRelayStatusPathForTest(t)
	p := &poller{relayInflight: true, relayGen: 2, relayLastState: "mac|a"}
	p.applyRelayResult(relayPushResult{key: "mac|b", at: time.Now(), err: &relayHTTPError{path: "/push", status: 401}, gen: 1})
	if p.relayInflight || p.relayFailKey != "" || p.relayBackoff != 0 || p.relayLastState != "mac|a" {
		t.Fatalf("旧配置的结果不记账: %+v", p)
	}
	if _, ok := readRelayStatusForTest(t, path); ok {
		t.Fatal("旧配置的结果不报状态")
	}
}

// 改了中继地址或令牌:去重锚点、退避、旧结论都清掉;别的配置变了不动它们。
func TestSyncLiveConfigResetsRelayPush(t *testing.T) {
	resetFeaturesForTest(t)
	setFeatures(featureFlags{})
	statusPath := useRelayStatusPathForTest(t)
	cfgPath := startLiveConfigForTest(t, `{"state_relay_url":"https://np.example","state_relay_token":"x"}`)
	now := time.Now()
	p := &poller{cfg: liveConfig(), relayLastState: "mac|a", relayLastAt: now, relayBackoff: time.Minute,
		relayFailKey: "mac|a", relayFailAt: now, relayFailingSince: now, relayStatusKey: "auth|401"}
	p.lfmKey = lastfmScrobblerKeyOf(p.cfg)
	writeRelayStatus(relayStatusFile{Schema: relayStatusSchema, Kind: relayFailAuth, Status: 401, Since: now.Unix()})

	writeConfigForTest(t, cfgPath, `{"state_relay_url":"https://np.example","state_relay_token":"x","listenbrainz_user":"u"}`)
	p.syncLiveConfig()
	if p.relayGen != 0 || p.relayLastState != "mac|a" || p.relayStatusKey != "auth|401" {
		t.Fatalf("中继没变不该重置: %+v", p)
	}
	if _, ok := readRelayStatusForTest(t, statusPath); !ok {
		t.Fatal("中继没变不该删状态")
	}

	writeConfigForTest(t, cfgPath, `{"state_relay_url":"https://np.example","state_relay_token":"y","listenbrainz_user":"u"}`)
	p.syncLiveConfig()
	if p.relayGen != 1 || p.relayLastState != "" || !p.relayLastAt.IsZero() || p.relayBackoff != 0 || p.relayFailKey != "" ||
		!p.relayFailingSince.IsZero() || p.relayStatusKey != "" {
		t.Fatalf("换了令牌要重置: %+v", p)
	}
	if _, ok := readRelayStatusForTest(t, statusPath); ok {
		t.Fatal("换了令牌要删旧结论")
	}
}

// 状态文件的形状跟 App 共用样例一致(Swift 侧 RelayPushStatus 读同一份)。
func TestRelayStatusMatchesSharedSamples(t *testing.T) {
	cases := map[string]relayStatusFile{
		"auth.json":    {Schema: relayStatusSchema, Kind: relayFailAuth, Status: 401, Since: 1_800_000_000},
		"network.json": {Schema: relayStatusSchema, Kind: relayFailNetwork, Since: 1_800_000_000},
	}
	for name, f := range cases {
		raw, err := os.ReadFile(filepath.Join("..", "shared", "testdata", "relay-status", name))
		if err != nil {
			t.Fatal(err)
		}
		got, err := json.Marshal(f)
		if err != nil {
			t.Fatal(err)
		}
		var want, have any
		if json.Unmarshal(raw, &want) != nil || json.Unmarshal(got, &have) != nil || !reflect.DeepEqual(want, have) {
			t.Errorf("%s: 样例 %s,引擎写出 %s", name, raw, got)
		}
	}
}

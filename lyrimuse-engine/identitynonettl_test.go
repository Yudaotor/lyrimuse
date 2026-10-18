package main

import (
	"testing"
	"time"
)

// 「认不出身份」的结论过 artistIdentityNoneTTL(或早先写下、没有时刻)就重查,占一份预算;没过期的直接用缓存。
func TestArtistIdentityNoneExpires(t *testing.T) {
	calls := withFakeMBFetch(t, fakeMBArtists(map[string][2]string{"Old None": {"某人", "Old None"}}, nil))
	artistIdentityMu.Lock()
	savedCache, savedPath := artistIdentityCache, artistIdentityPath
	artistIdentityCache, artistIdentityPath = map[string]mbArtistIdentity{
		"Old None":   {Checked: true},
		"Fresh None": {Checked: true, CheckedAt: time.Now().Unix()},
	}, ""
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		artistIdentityMu.Lock()
		artistIdentityCache, artistIdentityPath = savedCache, savedPath
		artistIdentityMu.Unlock()
	})

	resolve := budgetedArtistIdentity(1)
	if id := resolve("Fresh None", ""); id.Mbid != "" || len(*calls) != 0 {
		t.Errorf("没过期:直接用缓存、不发请求,got %+v calls=%v", id, *calls)
	}
	if id := resolve("Old None", ""); id.Mbid == "" {
		t.Errorf("没有时刻的旧结论算过期:重查、认出身份,got %+v", id)
	}
	artistIdentityMu.Lock()
	artistIdentityCache["Old None"] = mbArtistIdentity{Checked: true}
	artistIdentityMu.Unlock()
	before := len(*calls)
	if id := resolve("Old None", ""); id.Mbid != "" || len(*calls) != before {
		t.Errorf("预算用完:这一轮不再查,got %+v", id)
	}
}

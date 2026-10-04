package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// 换上假的 mbFetchBody、清空响应缓存,测试结束还原。
func withFakeMBFetch(t *testing.T, fetch func(url string) ([]byte, error)) *[]string {
	t.Helper()
	var calls []string
	origFetch := mbFetchBody
	mbResponseMu.Lock()
	origCache := mbResponseCache
	mbResponseCache = map[string]mbCachedResponse{}
	mbResponseMu.Unlock()
	mbFetchBody = func(_ context.Context, url string) ([]byte, error) {
		calls = append(calls, url)
		return fetch(url)
	}
	t.Cleanup(func() {
		mbFetchBody = origFetch
		mbResponseMu.Lock()
		mbResponseCache = origCache
		mbResponseMu.Unlock()
	})
	return &calls
}

func fakeMBArtist(url string) ([]byte, error) {
	if strings.Contains(url, "?query=") {
		return []byte(`{"artists":[{"id":"mbid-1","name":"Test Artist","score":100}]}`), nil
	}
	return []byte(`{"name":"Test Artist","country":"US","aliases":[{"name":"测试歌手","locale":"zh","type":"Artist name"}]}`), nil
}

// 找中文名和找别名对同一位歌手发的是同样两个请求,第二条必须直接用第一条的响应:
// 一位新歌手 2 个请求,不是 4 个(MusicBrainz 限速 1.1 秒一次,多出来的两个都要排队)。
func TestMBSharedResponsesDedupeAcrossLookups(t *testing.T) {
	calls := withFakeMBFetch(t, fakeMBArtist)
	ctx := context.Background()
	lookupMusicBrainzChineseAlias(ctx, "Test Artist")
	if _, err := lookupMusicBrainzArtistAliases(ctx, "Test Artist"); err != nil {
		t.Fatalf("lookupMusicBrainzArtistAliases: %v", err)
	}
	if len(*calls) != 2 {
		t.Fatalf("同一位歌手两条查询应当只发 2 个请求, got %d: %v", len(*calls), *calls)
	}
}

// 没查成的不存:下一次照样真去请求,不能在 TTL 内被一次偶发失败挡住。
func TestMBSharedResponsesDoNotCacheFailures(t *testing.T) {
	fail := true
	calls := withFakeMBFetch(t, func(url string) ([]byte, error) {
		if fail {
			return nil, errors.New("musicbrainz: status 503")
		}
		return fakeMBArtist(url)
	})
	ctx := context.Background()
	var v mbSearchResponse
	url := "https://musicbrainz.org/ws/2/artist/?query=Test+Artist&fmt=json&limit=5"
	if err := mbGetJSONShared(ctx, url, &v); err == nil {
		t.Fatal("第一次应当报错")
	}
	fail = false
	if err := mbGetJSONShared(ctx, url, &v); err != nil {
		t.Fatalf("第二次应当真去请求并成功: %v", err)
	}
	if len(*calls) != 2 || len(v.Artists) != 1 {
		t.Fatalf("失败不该被缓存: calls=%d artists=%d", len(*calls), len(v.Artists))
	}
}

// 过了 TTL 就不算命中;容量满了先丢过期的、再丢最旧的。
func TestMBResponseCacheTTLAndCapacity(t *testing.T) {
	withFakeMBFetch(t, fakeMBArtist)
	t0 := time.Unix(1_000_000, 0)
	mbStoreBody("u", []byte("{}"), t0)
	if _, ok := mbCachedBody("u", t0.Add(mbResponseTTL-time.Second)); !ok {
		t.Fatal("TTL 内应当命中")
	}
	if _, ok := mbCachedBody("u", t0.Add(mbResponseTTL)); ok {
		t.Fatal("到 TTL 应当失效")
	}
	for i := 0; i < mbResponseMaxItems+10; i++ {
		mbStoreBody("k"+string(rune('a'+i%26))+strings.Repeat("x", i), []byte("{}"), t0.Add(time.Duration(i)*time.Second))
	}
	mbResponseMu.Lock()
	n := len(mbResponseCache)
	mbResponseMu.Unlock()
	if n > mbResponseMaxItems {
		t.Fatalf("缓存条数 %d 超过上限 %d", n, mbResponseMaxItems)
	}
	if _, ok := mbCachedBody("u", t0.Add(time.Minute)); ok {
		t.Fatal("最旧的那条应当先被挤掉")
	}
}

package main

import (
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// 平台链接(enrichEntry 上的 xxx_url)从引擎到网页要过好几份手写的名单(docs/features/16 第 6 节):合并条目时
// 逐个字段补(mergePeripheralInto)、发给 ListenBrainz 和中继的那份字段(fields)、ListenBrainz 的
// additional_info 白名单(lbMeta)、中继的 links(relayState)、App 解码进 PlatformLinks(EnrichCacheReader)。
// 接新播放器时它的链接漏了哪一份都不报错,只是那一层悄悄没有这条链接。这里以 enrichEntry 上的字段为准,
// 每条链接从头走一遍。
func TestPlatformLinkFieldsReachEveryLayer(t *testing.T) {
	// 带 _url 但不是歌曲页的:封面、动态封面、设备封面在网上的同一张图、视频帧各有自己的去处,不归这条管。
	notSongPages := map[string]bool{"cover_url": true, "motion_cover_url": true, "motion_preview_url": true,
		"public_cover_url": true, "video_frame_url": true}
	// App 不读 spotify_url(本地拼的搜索页兜底),Spotify 曲目页由 spotify_track_id 换算(PlatformLinks.spotifySong)。
	appReads := map[string]string{"spotify_url": "spotify_track_id"}

	type link struct{ key, field string }
	var links []link
	full := enrichEntry{}
	rt := reflect.TypeOf(full)
	for i := 0; i < rt.NumField(); i++ {
		key, _, _ := strings.Cut(rt.Field(i).Tag.Get("json"), ",")
		if strings.HasSuffix(key, "_url") && !notSongPages[key] {
			links = append(links, link{key, rt.Field(i).Name})
		}
	}
	if len(links) == 0 {
		t.Fatal("enrichEntry 上一个平台链接字段都没认出来")
	}
	url := func(key string) string { return "https://example.com/" + key }
	for _, l := range links {
		reflect.ValueOf(&full).Elem().FieldByName(l.field).SetString(url(l.key))
	}

	raw, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift")
	if err != nil {
		t.Fatal(err)
	}
	swift := string(raw)
	start := strings.Index(swift, "public static func platformLinks(")
	if start < 0 {
		t.Fatal("EnrichCacheReader.swift 里没找到 platformLinks(签名改了就跟着改这条测试)")
	}
	feed := swift[start:]
	if end := strings.Index(feed, "\n    }\n"); end > 0 {
		feed = feed[:end]
	}

	withEnrichCache(t, map[string]enrichEntry{enrichKey("歌手", "歌名", "专辑"): full})
	s := snapshot{Artist: "歌手", Title: "歌名", Album: "专辑", Remote: true}
	sent := lbMeta(s).AdditionalInfo
	relayLinks, _ := relayState(s, true, "", 0, true)["links"].(map[string]any)
	relayed := map[any]bool{}
	for _, v := range relayLinks {
		relayed[v] = true
	}
	for _, l := range links {
		var loser enrichEntry
		reflect.ValueOf(&loser).Elem().FieldByName(l.field).SetString(url(l.key))
		if got := reflect.ValueOf(mergePeripheralInto(enrichEntry{}, loser)).FieldByName(l.field).String(); got != url(l.key) {
			t.Errorf("%s:合并条目时没从落选那条补过来(enrichkey.go mergePeripheralInto)", l.key)
		}
		if full.fields()[l.key] != url(l.key) {
			t.Errorf("%s:不在发给 ListenBrainz 和中继的字段里(enrich.go fields)", l.key)
		}
		if sent[l.key] != url(l.key) {
			t.Errorf("%s:ListenBrainz 的 additional_info 没带上(lb.go lbMeta 的白名单)", l.key)
		}
		if !relayed[url(l.key)] {
			t.Errorf("%s:中继推给网页的 links 里没有(relay.go relayState)", l.key)
		}
		key := l.key
		if alt, ok := appReads[key]; ok {
			key = alt
		}
		m := regexp.MustCompile(`case (\w+) = "` + regexp.QuoteMeta(key) + `"`).FindStringSubmatch(swift)
		if m == nil {
			t.Errorf("%s:App 没解码(EnrichCacheReader.swift 的 CodingKeys 里没有 %q)", l.key, key)
		} else if !strings.Contains(feed, "entry."+m[1]) {
			t.Errorf("%s:App 解码了却没交给 PlatformLinks(EnrichCacheReader.platformLinks 里没用 entry.%s)", l.key, m[1])
		}
	}
	if len(relayLinks) != len(links) {
		t.Errorf("中继的 links 有 %d 项,平台链接字段有 %d 个,两边要一一对应", len(relayLinks), len(links))
	}
}

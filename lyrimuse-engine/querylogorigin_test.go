package main

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

// 换名重查的每个名字带上它从哪一路来:CV 署名拆出的声优和团体、「英文名 + 中文名」里的汉字段、MusicBrainz、QQ。
func TestRetryArtistIdentitiesOrigins(t *testing.T) {
	cases := []struct {
		artist string
		alias  string
		mb     []string
		qq     string
		want   []artistIdentity
	}{
		{"来栖 翔(CV.下野 紘) & 组合名", "", nil, "", []artistIdentity{
			{name: "下野紘", origin: lyricQueryOriginCVActor}, {name: "组合名", origin: lyricQueryOriginCVUnit}}},
		{"Gary 曹格", "", nil, "", []artistIdentity{{name: "曹格", origin: lyricQueryOriginHanPortion}}},
		{"Faye Wong", "王菲", nil, "王靖雯", []artistIdentity{
			{name: "王菲", origin: lyricQueryOriginMBChinese}, {name: "王靖雯", origin: lyricQueryOriginQQArtist}}},
	}
	for _, c := range cases {
		withEnrichCache(t, nil)
		withCachedAliases(t, map[string]string{c.artist: c.alias})
		withCachedMBAliases(t, map[string][]string{c.artist: c.mb})
		withCachedQQArtistNames(t, map[string]string{c.artist: c.qq})
		got := retryArtistIdentitiesWithOrigin(context.Background(), c.artist)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("retryArtistIdentitiesWithOrigin(%q) = %v, 要 %v", c.artist, got, c.want)
		}
		if names := retryArtistIdentities(context.Background(), c.artist); !reflect.DeepEqual(names, identityNames(c.want)) {
			t.Errorf("retryArtistIdentities(%q) = %q, 要跟带出处的那份同样的名字 %q", c.artist, names, identityNames(c.want))
		}
	}
}

// 查询记录带上 ctx 上标的出处;没标时为空,序列化成 JSON 时不出现这个字段。日志里的写法是「名字(出处)」。
func TestLyricQueryRecordOrigin(t *testing.T) {
	ctx, log := withLyricQueryLog(context.Background())
	aliasCtx := withLyricQueryOrigin(withLyricQueryReason(ctx, lyricQueryReasonAliasRescue), lyricQueryOriginCVActor)
	log.record("原署名", "歌名", lyricQueryReasonFrom(ctx), lyricQueryOriginFrom(ctx), nil)
	log.record("声优甲", "歌名", lyricQueryReasonFrom(aliasCtx), lyricQueryOriginFrom(aliasCtx), nil)
	got := log.queries()
	if len(got) != 2 || got[0].Origin != "" || got[1].Origin != lyricQueryOriginCVActor || got[1].Reason != lyricQueryReasonAliasRescue {
		t.Fatalf("记录 = %+v", got)
	}
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if s := string(b); strings.Count(s, `"origin"`) != 1 || !strings.Contains(s, `"origin":"cv-actor"`) {
		t.Errorf("序列化 = %s,出处只该在第二条出现", s)
	}
	if s := (artistIdentity{name: "声优甲", origin: lyricQueryOriginCVActor}).String(); s != "声优甲(cv-actor)" {
		t.Errorf("日志写法 = %q", s)
	}
	if s := (artistIdentity{name: "首歌手"}).String(); s != "首歌手" {
		t.Errorf("没有出处时日志写法 = %q", s)
	}
}

// 每个出处在「解析决策」面板上都有译名,Swift 那边写了译名的出处这边也都登记过。
func TestLyricQueryOriginsHaveLabels(t *testing.T) {
	const sheet = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift"
	data, err := os.ReadFile(sheet)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", sheet, err)
	}
	src := string(data)
	const fnMarker = "private func queryOriginLabel("
	start := strings.Index(src, fnMarker)
	if start < 0 {
		t.Fatalf("%s 里找不到 queryOriginLabel —— 函数改名了就同步改这个测试", sheet)
	}
	body := src[start:]
	if end := strings.Index(body, "\n    }\n"); end > 0 {
		body = body[:end]
	}
	known := map[string]bool{}
	for _, o := range lyricQueryOrigins() {
		known[o] = true
		if !strings.Contains(body, `case "`+o+`":`) {
			t.Errorf("出处 %q 在 LyricsDecisionSheet.queryOriginLabel 里没有译名", o)
		}
	}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `case "`) {
			continue
		}
		rest := strings.TrimPrefix(line, `case "`)
		if i := strings.Index(rest, `"`); i > 0 && !known[rest[:i]] {
			t.Errorf("Swift 里有出处 %q 的译名,但 lyricQueryOrigins() 没登记它", rest[:i])
		}
	}
}

// 别名轮三条抓取路径(救急并发、补缺席并发、串行)和首歌手变体轮都把名字的出处标进 ctx,记录点把它记下。
func TestLyricQueryOriginIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, needle := range []string{
		"lyricQueryLogFrom(ctx).record(artist, title, lyricQueryReasonFrom(ctx), lyricQueryOriginFrom(ctx), sortedLyricSourceOnly(ctx))",
		"retryIdentities := retryArtistIdentitiesWithOrigin(ctx, artist)",
		"identitiesFrom(catalogIdentities, lyricQueryOriginAppleCatalog)",
		"identitiesFrom(storefrontIdentities, lyricQueryOriginAppleStorefront)",
		"identitiesFrom(titleSearchIdentities, lyricQueryOriginAppleTitle)",
		"lyricQueryReasonAliasRescue), altIdentities[j].origin)",
		"lyricQueryReasonAliasMissing), altIdentities[j].origin)",
		"aliasReason), alt.origin)",
		"lyricQueryReasonPrimaryVar), alt.origin)",
		"range retryArtistIdentitiesWithOrigin(ctx, primary)",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("enrich.go 缺 %q —— 少一处,那一轮的名字在「解析决策」里就看不出出处", needle)
		}
	}
}

package main

import (
	"strings"
	"testing"
)

// Dean Lewis《Be Alright》(1400596082)TTML 头部的原样片段:立体声母带的时间轴,空间音频版要晚 1.672 秒。
const beAlrightTTMLHead = `<iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal" leadingSilence="0.040"><translations/>` +
	`<songwriters><songwriter>Dean Lewis</songwriter></songwriters><audio lyricOffset="1.672" role="spatial"/></iTunesMetadata>`

func TestApplemusicSpatialLyricOffset(t *testing.T) {
	cases := []struct {
		name string
		ttml string
		want float64
	}{
		{"实测头部", beAlrightTTMLHead, 1.672},
		{"负偏移", `<audio lyricOffset="-0.131" role="spatial"/>`, -0.131},
		{"属性顺序反过来", `<audio role="spatial" lyricOffset="0.5"/>`, 0.5},
		{"没有 audio 标签", `<iTunesMetadata leadingSilence="0.040"></iTunesMetadata>`, 0},
		{"不是空间音频那一路", `<audio lyricOffset="2.0" role="stereo"/>`, 0},
		{"读不出数", `<audio lyricOffset="abc" role="spatial"/>`, 0},
		{"超出上限当读错", `<audio lyricOffset="30" role="spatial"/>`, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := applemusicSpatialLyricOffset(c.ttml); got != c.want {
				t.Errorf("applemusicSpatialLyricOffset = %v, want %v", got, c.want)
			}
		})
	}
}

func TestApplemusicParseTTMLCarriesSpatialOffset(t *testing.T) {
	ttml := strings.Replace(appleTTMLSample, `</metadata>`, beAlrightTTMLHead+`</metadata>`, 1)
	p, ok := applemusicParseTTML(ttml)
	if !ok {
		t.Fatal("解析失败")
	}
	if p.spatialOffsetSecs != 1.672 {
		t.Errorf("spatialOffsetSecs = %v, want 1.672", p.spatialOffsetSecs)
	}
	if plain, _ := applemusicParseTTML(appleTTMLSample); plain.spatialOffsetSecs != 0 {
		t.Errorf("没有 audio 标签时应为 0,实得 %v", plain.spatialOffsetSecs)
	}
}

func TestApplemusicResultFromTagsSpatialOffset(t *testing.T) {
	var song applemusicSong
	song.Attributes.DurationInMillis = 196373
	p := amllResult{
		lrc:               "[00:04.10]I look up\n[00:07.28]You look away\n[00:08.97]And I see",
		yrc:               "[4107,3178](4107,267,0)I (4374,182,0)look",
		spatialOffsetSecs: 1.672,
	}
	r := applemusicResultFrom(song, p, false)
	if !strings.HasPrefix(r.lyrics, "[am-spatial:1672/196373]\n[00:04.10]") {
		t.Errorf("整行正文没带上标签: %q", r.lyrics)
	}
	if !strings.HasPrefix(r.yrc, "[am-spatial:1672/196373]\n[4107,3178]") {
		t.Errorf("逐字正文没带上标签: %q", r.yrc)
	}
	if !isTimedLRC(r.lyrics) {
		t.Error("带标签的正文仍应判成带时间轴")
	}
	if plain := applemusicResultFrom(song, amllResult{lrc: "I look up", spatialOffsetSecs: 1.672}, true); plain.lyrics != "I look up" {
		t.Errorf("纯文本不带标签,实得 %q", plain.lyrics)
	}
	var unknown applemusicSong
	if r := applemusicResultFrom(unknown, p, false); r.lyrics != p.lrc || r.yrc != p.yrc {
		t.Error("立体声时长未知时不带标签(App 没法判断在放哪一版)")
	}
	p.spatialOffsetSecs = 0
	if r := applemusicResultFrom(song, p, false); r.lyrics != p.lrc {
		t.Error("没有偏移时正文原样")
	}
}

func TestWithSpatialAudioTagReplacesExisting(t *testing.T) {
	once := withSpatialAudioTag("[00:01.00]a", 1.0, 200)
	twice := withSpatialAudioTag(once, 1.5, 200)
	if twice != "[am-spatial:1500/200000]\n[00:01.00]a" {
		t.Errorf("再加一次应换掉旧标签、只留一行,实得 %q", twice)
	}
}

// 启动期的两道正文重写(行时间轴重挂到逐字轴、逐字空白词条合并)都只动带时间戳的行,标签行要原样留下。
func TestSpatialAudioTagSurvivesStartupRewrites(t *testing.T) {
	tag := "[am-spatial:1672/196373]"
	lrc := tag + "\n[00:04.20]I look up\n[00:07.20]You look away\n[00:09.10]And I see"
	yrc := tag + "\n[4107,3178](4107,267,0)I (4374,182,0)look (4556,281,0)up\n" +
		"[7285,1216](7285,205,0)You (7490,221,0)look (7711,191,0)away\n" +
		"[8974,2121](8974,138,0)And (9112,167,0)I (9279,222,0)see"
	rehung, _, changed := rehangLRCOnYRC(lrc, yrc, 196, true)
	if !changed {
		t.Fatal("测试数据应触发重挂")
	}
	if !strings.HasPrefix(rehung, tag+"\n") {
		t.Errorf("重挂后标签行丢了: %q", rehung)
	}
	spaced := tag + "\n[4107,3178](4107,267,0)I(4374,10,0) (4384,172,0)look"
	merged, _ := yrcMergeWhitespaceTokens(spaced)
	if !strings.HasPrefix(merged, tag+"\n") {
		t.Errorf("合并空白词条后标签行丢了: %q", merged)
	}
}

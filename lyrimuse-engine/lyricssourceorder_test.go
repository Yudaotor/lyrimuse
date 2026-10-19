package main

import (
	"reflect"
	"testing"
)

// 用户排过的顺序里认得的项原样保留(去重、丢掉不认得的),没排进去的按默认顺序(全部源,再是「播放器自带歌词」)补在末尾。
func TestResolveLyricsSourceOrderAppendsMissing(t *testing.T) {
	defaults := append(append([]string{}, lyricsSourceDefaultOrder...), lyricsPriorityPlayerLocal)
	if got := resolveLyricsSourceOrder(nil); !reflect.DeepEqual(got, defaults) {
		t.Fatalf("空表 → 默认顺序, got %v", got)
	}
	got := resolveLyricsSourceOrder([]string{lyricSourceQQ, "nosuch", lyricSourceNetease, lyricSourceQQ})
	if len(got) != len(defaults) || got[0] != lyricSourceQQ || got[1] != lyricSourceNetease {
		t.Fatalf("手排的前两位保留、去重、丢掉不认得的, got %v", got)
	}
	var rest []string
	for _, s := range defaults {
		if s != lyricSourceQQ && s != lyricSourceNetease {
			rest = append(rest, s)
		}
	}
	if !reflect.DeepEqual(got[2:], rest) {
		t.Fatalf("没排进去的按默认顺序补在末尾, got %v want %v", got[2:], rest)
	}
	// 旧文件缺一个后来才加的源(soda):前面原样,soda 补最后。
	var old []string
	for _, s := range lyricsSourceDefaultOrder {
		if s != lyricSourceSoda {
			old = append([]string{s}, old...)
		}
	}
	got = resolveLyricsSourceOrder(old)
	if !reflect.DeepEqual(got[:len(old)], old) || got[len(got)-2] != lyricSourceSoda || got[len(got)-1] != lyricsPriorityPlayerLocal {
		t.Fatalf("新源补在末尾、其余照用户的顺序, got %v", got)
	}
	// 用户把「播放器自带歌词」排在第一位:原样保留。
	got = resolveLyricsSourceOrder([]string{lyricsPriorityPlayerLocal, lyricSourceQQ})
	if got[0] != lyricsPriorityPlayerLocal || got[1] != lyricSourceQQ || len(got) != len(defaults) {
		t.Fatalf("「播放器自带歌词」排在哪儿就在哪儿, got %v", got)
	}
}

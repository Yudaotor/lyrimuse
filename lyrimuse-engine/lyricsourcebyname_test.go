package main

import (
	"slices"
	"testing"
)

// 通用代码里原来按源名写、现在读描述符的几处判断:读出来的集合跟原来写的源名逐个相同。

// 「歌曲文件自带的歌词」这一类(PriorityPlacement 是 priorityFileLyrics)只有 localfile:优先用文件自带歌词的三处判断、
// 放本地文件的播放器认作自家的那一份,原来都直接写 localFileLyricsSource。
func TestFileLyricsKindIsOnlyLocalFile(t *testing.T) {
	names := []string{"", "nope", "manual"}
	for _, d := range builtinLyricRegistry().descriptors {
		names = append(names, d.Name)
	}
	for _, s := range names {
		if got, want := lyricSourceIsFileLyrics(s), s == localFileLyricsSource; got != want {
			t.Errorf("lyricSourceIsFileLyrics(%q) = %v,原来的判断(== localfile)是 %v", s, got, want)
		}
	}
	if got := builtinLyricRegistry().priorityFileNames; !slices.Equal(got, []string{localFileLyricsSource}) {
		t.Errorf("priorityFileNames = %v,期望只有 localfile", got)
	}

	savedBundleID := playerBundleIDs[playingPlayer()]
	t.Cleanup(func() { setNativeLyricSourcesForPlayer(savedBundleID) })
	checked := 0
	for player, native := range playerNativeLyricSources {
		setNativeLyricSourcesForPlayer(playerBundleIDs[player])
		if playingPlayer() != player {
			t.Fatalf("没能把正在放的播放器设成 %s", player)
		}
		want := map[string]bool{}
		if native != "" {
			want[native] = true
		}
		if playsLocalFilesBesidesStreaming(player) {
			want[localFileLyricsSource] = true
			checked++
		}
		for _, s := range names {
			if isNativeLyricSource(s) != want[s] {
				t.Errorf("用 %s 放歌时 %q 算不算自家的歌词源:%v,期望 %v", player, s, isNativeLyricSource(s), want[s])
			}
		}
	}
	if checked == 0 {
		t.Error("没有一个播放器是流媒体之外还放本地文件的:这条用例没测到那一支")
	}
}

// 「同源候选当初落选」不重来的那几个来源:原来写的是 kkbox、amazon、localfile、lxmusic 四个名字,现在读 Kind 是不是播放器
// 本机的。Kind 是播放器本机的还有 Spotify 本地歌词,它不是任何播放器的自家歌词源,排在 isNativeLyricSource 后面判不到它。
func TestNativeMissedOutSkipsPlayerLocalKinds(t *testing.T) {
	handwritten := func(s string) bool {
		return s != kkboxLocalLyricsSource && s != amazonLocalLyricsSource && s != localFileLyricsSource && s != lxMusicLocalLyricsSource
	}
	native := map[string]bool{localFileLyricsSource: true}
	for player, s := range playerNativeLyricSources {
		if s == spotifyLocalLyricsSource {
			t.Errorf("%s 把 Spotify 本地歌词登记成了自家歌词源:needsLyricsRetry 里按 Kind 判就跟原来按名字判不一样了", player)
		}
		if s != "" {
			native[s] = true
		}
	}
	local := 0
	for s := range native {
		d := builtinLyricRegistry().descriptor(s)
		if d == nil {
			t.Errorf("播放器目录里的自家歌词源 %q 没登记", s)
			continue
		}
		if got, want := !lyricSourceKindIs(s, providerKindPlayerLocal), handwritten(s); got != want {
			t.Errorf("%s:按 Kind 判走不走「同源落选重来」= %v,原来按名字判是 %v", s, got, want)
		}
		if d.Kind == providerKindPlayerLocal {
			local++
		}
	}
	if local != 4 {
		t.Errorf("能当自家歌词源的播放器本机来源应是四个,得到 %d 个", local)
	}
}

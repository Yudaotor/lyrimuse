package main

import "sync"

// Kaset 放的这首在 YouTube Music 上的歌曲页。App 把 Kaset 报的 videoId 经播放状态带过来
// (`track.youtube_music_video_id`),这里记下这一拍的曲目,解析歌词那一轮按歌名歌手认出是同一首才拼成链接存进缓存。

var (
	kasetCurrentMu sync.Mutex
	// kasetCurrentTrack:App 此刻报的 Kaset 那首(歌手 / 歌名 + videoId)。
	kasetCurrentTrack struct{ artist, title, videoID string }
)

// noteKasetCurrentTrack 记下 App 这一拍报的当前曲目。不是 Kaset、或者没带 videoId 就清空。
func noteKasetCurrentTrack(bundleID, artist, title, videoID string) {
	if bundleID != kasetBundleID || videoID == "" {
		artist, title, videoID = "", "", ""
	}
	kasetCurrentMu.Lock()
	defer kasetCurrentMu.Unlock()
	kasetCurrentTrack.artist, kasetCurrentTrack.title, kasetCurrentTrack.videoID = artist, title, videoID
}

// youtubeMusicWatchURL:videoId 换成 YouTube Music 歌曲页。videoId 是 11 位字母数字加 `-` `_`,别的形状不给
// (App 侧 PlatformLinks.youtubeMusicWatchURL 同一道闸)。
func youtubeMusicWatchURL(videoID string) string {
	if len(videoID) != 11 {
		return ""
	}
	for _, c := range videoID {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return ""
		}
	}
	return "https://music.youtube.com/watch?v=" + videoID
}

// kasetVideoIDFor:正用 Kaset 放、而且 App 带来了这首的 videoId,返回它。解析那一轮拿到的歌名已经过 normEnrichTitle
// (MV 标记这类尾巴剥掉了),App 报的是原样的,两边都归一了再比。
func kasetVideoIDFor(bundleID, artist, title string) string {
	if bundleID != kasetBundleID {
		return ""
	}
	kasetCurrentMu.Lock()
	defer kasetCurrentMu.Unlock()
	if kasetCurrentTrack.artist != artist || normEnrichTitle(kasetCurrentTrack.title) != normEnrichTitle(title) {
		return ""
	}
	return kasetCurrentTrack.videoID
}

// kasetListedAlbumFor:Kaset 这首(videoId)在 YouTube Music 上登记的专辑。专辑只登记在音轨版本上,按队列里记下的音轨
// videoId 问;还没问过就后台去问,这一回先给空(见 ytmusicCreditCachedOrFetch)。
func kasetListedAlbumFor(videoID string) string {
	if videoID == "" {
		return ""
	}
	return ytmusicCreditCachedOrFetch(kasetAudioVideoIDFor(videoID)).album
}

// youtubeMusicTrackURLFor:正用 Kaset 放的这首的 YouTube Music 歌曲页(认这一首的规则见 kasetVideoIDFor)。
func youtubeMusicTrackURLFor(bundleID, artist, title string) string {
	return youtubeMusicWatchURL(kasetVideoIDFor(bundleID, artist, title))
}

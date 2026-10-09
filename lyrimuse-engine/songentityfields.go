package main

// 缓存条目(enrichEntry)每个字段归哪一级、实体同步时跟不跟着走(18 章「字段归属」)。加字段时必须在这里登记:
// TestSongEntityFieldsRegistered 枚举全部 JSON 键,没登记的、登记了却已经没有的都红。

// songFieldClass:一个字段的归属。
type songFieldClass string

const (
	// songFieldLyricsChoice:歌曲 · 歌词选择。跟着实体的歌词选择走。
	songFieldLyricsChoice songFieldClass = "song.lyrics"
	// songFieldUserJudgment:歌曲 · 用户判断。留在用户操作的那条写法上,不以实体 id 为键。
	songFieldUserJudgment songFieldClass = "song.user"
	// songFieldRecording:歌曲 · 附属与录音属性。译文那几项跟着正文走。
	songFieldRecording songFieldClass = "song.recording"
	// songFieldBookkeeping:歌曲 · 记账(重试、补空、重评、机翻的次数与时刻)。
	songFieldBookkeeping songFieldClass = "song.bookkeeping"
	// songFieldTrackID:发行曲目 · 平台 id。留在写法上,并进实体的 ids。
	songFieldTrackID songFieldClass = "release_track.id"
	// songFieldAlbum:专辑(封面、动态封面、各平台专辑 id)。
	songFieldAlbum songFieldClass = "album"
	// songFieldArtist:歌手。
	songFieldArtist songFieldClass = "artist"
	// songFieldVariant:写法自己的(这一版的时长、播放器封面、检索用的登记专辑……),不同步。
	songFieldVariant songFieldClass = "variant"
	// songFieldDecision:写法 · 解析决策留痕,不同步。
	songFieldDecision songFieldClass = "variant.decision"
)

// songEntityFieldClasses:enrichEntry 的 JSON 键 → 归属。
var songEntityFieldClasses = map[string]songFieldClass{
	"lyrics": songFieldLyricsChoice, "lyrics_tr": songFieldLyricsChoice, "lyrics_roma": songFieldLyricsChoice,
	"lyrics_yrc": songFieldLyricsChoice, "lyrics_bg": songFieldLyricsChoice, "lyrics_bg_checked": songFieldLyricsChoice,
	"body_crc": songFieldLyricsChoice, "body_fields": songFieldLyricsChoice, "lyrics_source": songFieldLyricsChoice,
	"lyrics_score": songFieldLyricsChoice, "lyrics_scoring_version": songFieldLyricsChoice,
	"lyrics_scoring_revision": songFieldLyricsChoice,
	"resolved_duration_secs":  songFieldLyricsChoice, "lyrics_speakers": songFieldLyricsChoice,
	"lyrics_speakers_checked": songFieldLyricsChoice, "plain_lyrics": songFieldLyricsChoice,
	"plain_lyrics_source": songFieldLyricsChoice,

	"manual_lyrics": songFieldUserJudgment, "manual_pick_sha": songFieldUserJudgment,
	"lyrics_source_choice": songFieldUserJudgment, "instrumental": songFieldUserJudgment,
	"instrumental_cleared": songFieldUserJudgment,

	"lyrics_songwriters": songFieldRecording, "song_language": songFieldRecording, "lyrics_tr_source": songFieldRecording,
	"lyrics_tr_lang": songFieldRecording, "translation_lang": songFieldRecording, "isrcs": songFieldRecording,

	"lyrics_retry_ts": songFieldBookkeeping, "lyrics_retry_count": songFieldBookkeeping, "lyrics_fill_ts": songFieldBookkeeping,
	"lyrics_fill_count": songFieldBookkeeping, "lyrics_rescore_count": songFieldBookkeeping,
	"lyrics_rescore_ts": songFieldBookkeeping, "lyrics_rescore_version": songFieldBookkeeping,
	"lyrics_rescore_revision": songFieldBookkeeping,
	"translation_retry_count": songFieldBookkeeping, "translation_ts": songFieldBookkeeping,

	"apple_music_url": songFieldTrackID, "netease_url": songFieldTrackID, "qq_music_url": songFieldTrackID,
	"spotify_url": songFieldTrackID, "spotify_track_id": songFieldTrackID, "kkbox_url": songFieldTrackID,
	"amazon_url": songFieldTrackID, "youtube_music_url": songFieldTrackID, "soda_url": songFieldTrackID,
	"isrc_lookup": songFieldTrackID,

	"cover_url": songFieldAlbum, "cover_source": songFieldAlbum, "cover_album": songFieldAlbum, "accent_color": songFieldAlbum,
	"motion_cover_url": songFieldAlbum, "motion_preview_url": songFieldAlbum, "motion_cover_checked": songFieldAlbum,
	"motion_cover_identity_verified": songFieldAlbum, "qq_album_mid": songFieldAlbum, "spotify_album_id": songFieldAlbum,
	"kkbox_album_id": songFieldAlbum, "amazon_album_asin": songFieldAlbum, "soda_album_id": songFieldAlbum,
	"youtube_music_album": songFieldAlbum, "youtube_music_album_id": songFieldAlbum,
	"youtube_music_album_lang": songFieldAlbum, "youtube_music_album_rev": songFieldAlbum,
	"cover_upgrade_check_ts": songFieldAlbum, "cover_upgrade_check_rules": songFieldAlbum,
	"cover_missing_retry_rules": songFieldAlbum, "inferred_album": songFieldAlbum,

	"canonical_artist": songFieldArtist, "inferred_artist": songFieldArtist, "qq_singer_mid": songFieldArtist,
	"spotify_artist_id": songFieldArtist, "kkbox_artist_id": songFieldArtist, "amazon_artist_asin": songFieldArtist,
	"soda_artist_id": songFieldArtist, "youtube_music_artist_id": songFieldArtist,

	"duration_secs": songFieldVariant, "player_covers": songFieldVariant, "public_cover_url": songFieldVariant,
	"public_cover_for": songFieldVariant, "video_frame_url": songFieldVariant, "youtube_music_mv": songFieldVariant,
	"lyrics_native_video_id": songFieldVariant, "lyrics_listed_album": songFieldVariant,
	"lyrics_search_title": songFieldVariant, "ts": songFieldVariant, "peripheral_ts": songFieldVariant,
	"peripheral_retry_count": songFieldVariant,

	"lyrics_decision": songFieldDecision, "lyrics_decision_applied": songFieldDecision,
	"lyrics_sources_seen": songFieldDecision, "lyrics_sources_responded": songFieldDecision,
	"lyrics_sources_skipped": songFieldDecision,
}

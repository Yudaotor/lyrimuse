package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	neturl "net/url"
	"sync"
	"time"
)

// ---- QQ 各接口的备用 ----
//
// QQ 这一源的每个接口都至少有两条路,前一条没问成就走下一条;一直挂着的那条由出站闸的接口熔断
// 跳过(hostguard.go),不会每次都白打。两层备用:
//   - 同一个接口的备用主机:网页接口挂在 qqWebHosts 这几个主机上,客户端网关挂在 qqMusicuHosts
//     这几个主机上。单个主机上的单个接口会单独下线,同主机别的接口照常(docs/features/09 第 84 条)。
//   - 另一套后端:网页接口(一个功能一个地址)和客户端网关(musicu.fcg,QQ 客户端自己用的统一
//     入口)互为备用。
//
// 只有「没问成」才换下一条:传输失败、非 200、解不开、拒绝码。接口正常答了(哪怕是查无结果)
// 就停,同一个问题不去问第二遍。
//
// 各接口的备用链:
//   - 搜歌:client_search_cp(qqClientSearchBases)→ 网关搜索
//   - smartbox:qqWebHosts;专辑分类再退到网关的专辑搜索;歌手联想只换主机(见 qqSingerSuggestionsAt)
//   - 单曲详情:fcg_play_single_song(qqWebHosts)→ 网关 get_song_detail_yqq
//   - 整行歌词:fcg_query_lyric_new(qqWebHosts)→ 网关 GetPlayLyricInfo(不加密)
//   - 专辑曲目表:网关 GetAlbumSongList → fcg_v8_album_info_cp(qqWebHosts)
//   - 逐字歌词 / 译文 / 罗马音、匿名会话:只有网关这一套,换 qqMusicuHosts 的主机
//
// 主机和字段都逐个实测过,响应结构各主机一致,实测记录见 docs/features/09 第 87 条。

var (
	qqWebHosts    = []string{"c.y.qq.com", "shc.y.qq.com", "i.y.qq.com"}
	qqMusicuHosts = []string{"u.y.qq.com", "u6.y.qq.com", "shu.y.qq.com"}
)

// errQQNotReached:这次没问成(不是「查无」)。
var errQQNotReached = errors.New("qq: not reached")

// qqTryHosts 按顺序对每个主机调 try,第一个返回 nil 的就停;全部失败返回最后一个错误。ctx 已取消
// 时不再试下一个。try 只在没问成时返回错误,接口正常答了(包括查无)要返回 nil。
func qqTryHosts(ctx context.Context, hosts []string, try func(host string) error) error {
	lastErr := errQQNotReached
	for _, h := range hosts {
		err := try(h)
		if err == nil {
			return nil
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return lastErr
}

// qqSearchComm:网关搜索要用桌面客户端这组公共参数,拿 qqCommBase(手机版)去调会回 request.code
// 2001(实测)。
var qqSearchComm = map[string]any{"ct": "19", "cv": "1859"}

// qqMusicuSearchSongs 走客户端网关搜歌,结果字段跟 client_search_cp(new_json=1)同形,归一方式
// 共用 qqClientSearchItems。
func qqMusicuSearchSongs(ctx context.Context, query string) ([]qqSearchItem, error) {
	data, err := qqMusicuPost(ctx, "DoSearchForQQMusicDesktop", "music.search.SearchCgiService", map[string]any{
		"query": query, "num_per_page": qqSearchLimit, "page_num": 1, "search_type": 0,
	}, qqSearchComm)
	if err != nil {
		return nil, err
	}
	var out struct {
		Body struct {
			Song json.RawMessage `json:"song"`
		} `json:"body"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	var resp qqClientSearchResp
	if len(out.Body.Song) > 0 {
		if err := json.Unmarshal(out.Body.Song, &resp.Data.Song); err != nil {
			return nil, err
		}
	}
	return qqClientSearchItems(resp), nil
}

// qqMusicuSearchAlbums 走客户端网关的专辑搜索(search_type 2),归一成 smartbox 专辑分类的条目形状。
func qqMusicuSearchAlbums(ctx context.Context, query string) ([]qqSmartboxItem, error) {
	data, err := qqMusicuPost(ctx, "DoSearchForQQMusicDesktop", "music.search.SearchCgiService", map[string]any{
		"query": query, "num_per_page": qqSearchLimit, "page_num": 1, "search_type": 2,
	}, qqSearchComm)
	if err != nil {
		return nil, err
	}
	var out struct {
		Body struct {
			Album struct {
				List []struct {
					AlbumMID   string `json:"albumMID"`
					AlbumName  string `json:"albumName"`
					SingerName string `json:"singerName"`
				} `json:"list"`
			} `json:"album"`
		} `json:"body"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	items := make([]qqSmartboxItem, 0, len(out.Body.Album.List))
	for _, a := range out.Body.Album.List {
		items = append(items, qqSmartboxItem{Mid: a.AlbumMID, Name: a.AlbumName, Singer: a.SingerName})
	}
	return items, nil
}

// qqMusicuLineLyric 走客户端网关取整行歌词(crypt=0,正文 base64)。只给歌词或纯音乐结论,不下
// 「这首歌没词」的结论:那条判据(trackFoundNoLyrics)只按网页接口的实测形态定过。
func qqMusicuLineLyric(ctx context.Context, mid string) qqLyricResult {
	data, err := qqMusicuPost(ctx, "GetPlayLyricInfo", "music.musichallSong.PlayLyricInfo", map[string]any{
		"songMID": mid, "crypt": 0, "qrc": 0, "trans": 0, "roma": 0, "type": 0, "ct": 19, "cv": 2111,
	}, qqCommBase)
	if err != nil {
		return qqLyricResult{}
	}
	var out struct {
		Lyric string `json:"lyric"`
	}
	if err := json.Unmarshal(data, &out); err != nil || out.Lyric == "" {
		return qqLyricResult{}
	}
	lyric := out.Lyric
	if dec, err := base64.StdEncoding.DecodeString(lyric); err == nil {
		lyric = string(dec)
	}
	if isInstrumentalPlaceholderLyric(lyric) {
		return qqLyricResult{instrumental: true}
	}
	if isTimedLRC(lyric) {
		return qqLyricResult{lrc: lyric}
	}
	return qqLyricResult{}
}

// qqAlbumSongsWeb 是网页版专辑接口(fcg_v8_album_info_cp),给 qqAlbumSongs 的网关那条当备用。
func qqAlbumSongsWeb(ctx context.Context, albumMid string) ([]qqAlbumSong, error) {
	var songs []qqAlbumSong
	err := qqTryHosts(ctx, qqWebHosts, func(host string) error {
		got, err := qqAlbumSongsWebAt(ctx, host, albumMid)
		if err == nil {
			songs = got
		}
		return err
	})
	return songs, err
}

func qqAlbumSongsWebAt(ctx context.Context, host, albumMid string) ([]qqAlbumSong, error) {
	u := "https://" + host + "/v8/fcg-bin/fcg_v8_album_info_cp.fcg?format=json&albummid=" + neturl.QueryEscape(albumMid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("album_info_cp status %d", resp.StatusCode)
	}
	var out struct {
		Code int `json:"code"`
		Data struct {
			List []struct {
				SongMid  string  `json:"songmid"`
				SongName string  `json:"songname"`
				Interval float64 `json:"interval"`
				Singer   []struct {
					Name string `json:"name"`
				} `json:"singer"`
			} `json:"list"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	if out.Code != 0 {
		return nil, fmt.Errorf("album_info_cp code %d", out.Code)
	}
	songs := make([]qqAlbumSong, 0, len(out.Data.List))
	for _, s := range out.Data.List {
		if s.SongMid == "" || s.SongName == "" {
			continue
		}
		var singers []string
		for _, sg := range s.Singer {
			if sg.Name != "" {
				singers = append(singers, sg.Name)
			}
		}
		singer := ""
		if len(singers) > 0 {
			singer = singers[0]
		}
		songs = append(songs, qqAlbumSong{mid: s.SongMid, name: s.SongName, singer: singer, singers: singers, interval: s.Interval})
	}
	return songs, nil
}

// ---- 单曲详情 ----
//
// 专辑名、封面、歌手 mid、数字 songID、官方时长、语种都出自同一条单曲详情,按 mid 缓存一份,
// qqSongAlbum / qqSongCoverAndSinger / qqSongCatalogMids / qqSongMetaByMid 都从这里取。

type qqSongDetailSinger struct {
	mid, name string
}

type qqSongDetailInfo struct {
	id        int64
	interval  float64
	language  int
	albumMid  string
	albumName string
	singers   []qqSongDetailSinger
}

// qqSongDetailRow 是网页接口 data[0] 与网关 track_info 共同的字段(两边同名,实测)。
type qqSongDetailRow struct {
	ID       int64   `json:"id"`
	Interval float64 `json:"interval"`
	Language int     `json:"language"`
	Album    struct {
		Mid  string `json:"mid"`
		Name string `json:"name"`
	} `json:"album"`
	Singer []struct {
		Mid  string `json:"mid"`
		Name string `json:"name"`
	} `json:"singer"`
}

func (r qqSongDetailRow) info() qqSongDetailInfo {
	d := qqSongDetailInfo{id: r.ID, interval: r.Interval, language: r.Language, albumMid: r.Album.Mid, albumName: r.Album.Name}
	for _, s := range r.Singer {
		d.singers = append(d.singers, qqSongDetailSinger{mid: s.Mid, name: s.Name})
	}
	return d
}

var (
	qqSongDetailMu    sync.Mutex
	qqSongDetailCache = map[string]qqSongDetailInfo{}
)

// qqSongDetail 取一首歌的单曲详情:网页接口(几个主机)→ 客户端网关。ok=false 是没取到(没问成,或
// 接口答了但没有这首)。只缓存取到了的。
func qqSongDetail(ctx context.Context, mid string) (qqSongDetailInfo, bool) {
	if mid == "" {
		return qqSongDetailInfo{}, false
	}
	qqSongDetailMu.Lock()
	if v, ok := qqSongDetailCache[mid]; ok {
		qqSongDetailMu.Unlock()
		return v, true
	}
	qqSongDetailMu.Unlock()

	var row qqSongDetailRow
	found := false
	err := qqTryHosts(ctx, qqWebHosts, func(host string) error {
		r, ok, err := qqSongDetailWebAt(ctx, host, mid)
		if err == nil {
			row, found = r, ok
		}
		return err
	})
	if err != nil {
		// 网页接口几个主机都没问成:退到客户端网关。
		data, merr := qqMusicuPost(ctx, "get_song_detail_yqq", "music.pf_song_detail_svr", map[string]any{
			"song_mid": mid, "song_type": 0,
		}, qqCommBase)
		if merr == nil {
			var out struct {
				TrackInfo qqSongDetailRow `json:"track_info"`
			}
			if json.Unmarshal(data, &out) == nil {
				row, found = out.TrackInfo, out.TrackInfo.ID != 0 || out.TrackInfo.Album.Mid != ""
			}
		}
	}
	if !found {
		return qqSongDetailInfo{}, false
	}
	d := row.info()
	qqSongDetailMu.Lock()
	qqSongDetailCache[mid] = d
	qqSongDetailMu.Unlock()
	if d.id != 0 {
		qqSongMetaMu.Lock()
		qqSongMetaCache[mid] = qqSongMeta{id: d.id, interval: d.interval, language: d.language}
		qqSongMetaMu.Unlock()
	}
	return d, true
}

// qqSongDetailWebAt:err 非 nil 是没问成;ok=false、err=nil 是接口答了但没有这首。
func qqSongDetailWebAt(ctx context.Context, host, mid string) (qqSongDetailRow, bool, error) {
	u := "https://" + host + "/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq&inCharset=utf8&outCharset=utf-8&songmid=" + neturl.QueryEscape(mid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return qqSongDetailRow{}, false, err
	}
	req.Header.Set("Referer", "https://y.qq.com/")
	req.Header.Set("User-Agent", qqUA)
	resp, err := doHTTPTracked(lyricHTTPClient(6*time.Second), req)
	if err != nil {
		return qqSongDetailRow{}, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return qqSongDetailRow{}, false, fmt.Errorf("single_song status %d", resp.StatusCode)
	}
	var out struct {
		Data []qqSongDetailRow `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return qqSongDetailRow{}, false, err
	}
	if len(out.Data) == 0 {
		return qqSongDetailRow{}, false, nil
	}
	return out.Data[0], true, nil
}

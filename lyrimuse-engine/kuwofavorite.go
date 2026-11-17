package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"
)

// 酷我音乐的「喜欢」状态:这首在不在当前账号的「我喜欢听」。App 按酷我「编辑」菜单的收藏/取消收藏写,读交给这里
// (App 不读别的 App 的容器,读容器要过 otherAppContainer 的「完全磁盘访问」闸)。见 02 章决策 267。
//
// 容器 DocumentData/cloud.db:
//   - userInfo:每个登录过的账号一行,uid 是十进制 id 的 base64;当前账号取 is_autologin 为 1 的那一行(几个取 time 最近的)。
//     没有自动登录的账号当没登录,不读(没登录那套列表挂在 uid 0 底下,行为没测)。
//   - playlistsInfo:type 3 是「我喜欢听」,每个账号一行;playlistMusics 按 playlist_id + rid 记歌,酷我自己判心形就是
//     `SELECT COUNT(1) FROM playlistMusics WHERE playlist_id=%llu AND rid=%llu`。
//
// 这首的 rid 按歌名、歌手在播放列表(kwmusic.db 的 PlayList.PersistentId)里找,不在列表里(电台)看它落盘的歌词文件名;
// 对上不止一个 rid 不猜。两个库都只读打开(mode=ro,回滚日志模式,不建文件、不锁它的写)。

// kuwoFavoriteDBOverride 让单测把 cloud.db 指到临时路径。空 = 用真实路径。
var kuwoFavoriteDBOverride string

// kuwoFavoriteQueryTimeout:一次查两个库的上限。App 按完菜单会隔 0.1 秒问一次,撞上客户端写锁时宁可这一拍读不到。
const kuwoFavoriteQueryTimeout = 2 * time.Second

func kuwoFavoriteDBPath() string {
	if kuwoFavoriteDBOverride != "" {
		return kuwoFavoriteDBOverride
	}
	return kuwoContainerDocumentDir("cloud.db")
}

// runKuwoFavoriteCLI:`lyrimuse-engine kuwo-favorite -title <歌名> -artist <歌手>`,打一行 JSON:
// 读到了是 `{"favorited":true}` / `{"favorited":false}`,读不到(没授权、没登录、认不出这首)是 `{}`。
func runKuwoFavoriteCLI(args []string) {
	var title, artist string
	for i := 0; i+1 < len(args); i += 2 {
		switch args[i] {
		case "-title":
			title = args[i+1]
		case "-artist":
			artist = args[i+1]
		}
	}
	out := map[string]bool{}
	if fav, ok := kuwoFavorited(title, artist); ok {
		out["favorited"] = fav
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, "kuwo-favorite: encode:", err)
		os.Exit(1)
	}
}

// kuwoFavorited 读这首喜欢了没有;ok=false 是读不到。
func kuwoFavorited(title, artist string) (favorited, ok bool) {
	if strings.TrimSpace(title) == "" {
		return false, false
	}
	cloud, queue := kuwoFavoriteDBPath(), kuwoUpcomingPath()
	if cloud == "" || queue == "" {
		return false, false
	}
	if _, err := os.Stat(cloud); err != nil {
		return false, false
	}
	var names []string
	if dir := kuwoLocalLyricDir(); dir != "" {
		if ents, err := os.ReadDir(dir); err == nil {
			for _, e := range ents {
				names = append(names, e.Name())
			}
		}
	}
	lyric := kuwoLyricRIDs(names, artist, title)
	ctx, cancel := context.WithTimeout(context.Background(), kuwoFavoriteQueryTimeout)
	defer cancel()
	uri := (&url.URL{Scheme: "file", Path: cloud, RawQuery: "mode=ro"}).String()
	out, err := exec.CommandContext(ctx, "/usr/bin/sqlite3", "-init", "/dev/null", "-batch", uri,
		kuwoFavoriteQuery(title, artist, lyric, queue)).Output()
	if err != nil {
		if sqliteSchemaMismatch(err) {
			noteParserUnrecognized("kuwo-favorite", sqliteErrorDetail(err))
		}
		return false, false
	}
	snap, ok := parseKuwoFavoriteOutput(string(out))
	if !ok {
		noteParserUnrecognized("kuwo-favorite", "cloud.db rows did not parse")
		return false, false
	}
	return kuwoFavoritedIn(snap, lyric)
}

func kuwoSQLString(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// kuwoFavoriteQuery 一次查完:主库 cloud.db,播放列表只读挂成 q。每行第一列是标签(U 账号、P「我喜欢听」、
// Q 播放列表里对上的 rid、M「我喜欢听」里的候选)。只输出数字和 base64,按 `|` 拆不会错位。
func kuwoFavoriteQuery(title, artist string, lyricRIDs []int64, queuePath string) string {
	queueURI := (&url.URL{Scheme: "file", Path: queuePath, RawQuery: "mode=ro"}).String()
	match := "FROM q.PlayList WHERE Title = " + kuwoSQLString(title) + " AND Artist = " + kuwoSQLString(artist)
	candidates := "SELECT CAST(PersistentId AS INTEGER) " + match
	if len(lyricRIDs) > 0 {
		vals := make([]string, len(lyricRIDs))
		for i, r := range lyricRIDs {
			vals[i] = "(" + strconv.FormatInt(r, 10) + ")"
		}
		candidates += " UNION VALUES " + strings.Join(vals, ", ")
	}
	return strings.Join([]string{
		"ATTACH " + kuwoSQLString(queueURI) + " AS q",
		"SELECT 'U', uid, is_autologin, time FROM userInfo",
		"SELECT 'P', id, uid FROM playlistsInfo WHERE type = 3",
		"SELECT 'Q', CAST(PersistentId AS INTEGER) " + match,
		"SELECT 'M', playlist_id, rid FROM playlistMusics WHERE playlist_id IN (SELECT id FROM playlistsInfo WHERE type = 3) " +
			"AND rid IN (" + candidates + ")",
	}, "; ") + ";"
}

type kuwoFavoriteUser struct {
	encodedUID string
	autoLogin  bool
	time       string
}

type kuwoFavoriteSnapshot struct {
	users     []kuwoFavoriteUser
	lists     map[int64]string // 「我喜欢听」列表 id → uid
	queueRIDs []int64
	members   [][2]int64 // (列表 id, rid)
}

// parseKuwoFavoriteOutput 拆 sqlite3 的输出;有认不出的行(表结构变了)ok=false,零行照常。
func parseKuwoFavoriteOutput(out string) (kuwoFavoriteSnapshot, bool) {
	s := kuwoFavoriteSnapshot{lists: map[int64]string{}}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		f := strings.Split(line, "|")
		n := func(i int) (int64, bool) {
			v, err := strconv.ParseInt(f[i], 10, 64)
			return v, err == nil
		}
		switch {
		case f[0] == "U" && len(f) == 4:
			s.users = append(s.users, kuwoFavoriteUser{encodedUID: f[1], autoLogin: f[2] == "1", time: f[3]})
		case f[0] == "P" && len(f) == 3:
			id, ok := n(1)
			if !ok {
				return s, false
			}
			if _, dup := s.lists[id]; dup {
				return s, false
			}
			s.lists[id] = f[2]
		case f[0] == "Q" && len(f) == 2:
			rid, ok := n(1)
			if !ok {
				return s, false
			}
			s.queueRIDs = append(s.queueRIDs, rid)
		case f[0] == "M" && len(f) == 3:
			list, ok1 := n(1)
			rid, ok2 := n(2)
			if !ok1 || !ok2 {
				return s, false
			}
			s.members = append(s.members, [2]int64{list, rid})
		default:
			return s, false
		}
	}
	return s, true
}

// kuwoCurrentUID 当前账号的 uid(十进制串):自动登录的那几行里最近登录的一行。没有、uid 0、解不开为 ""。
func kuwoCurrentUID(users []kuwoFavoriteUser) string {
	var best *kuwoFavoriteUser
	for i := range users {
		if users[i].autoLogin && (best == nil || users[i].time > best.time) {
			best = &users[i]
		}
	}
	if best == nil {
		return ""
	}
	raw, err := base64.StdEncoding.DecodeString(best.encodedUID)
	uid := string(raw)
	if err != nil || uid == "" || uid == "0" || strings.Trim(uid, "0123456789") != "" {
		return ""
	}
	return uid
}

// kuwoFavoriteRID 这首的 rid:播放列表里按歌名歌手对上的和歌词文件名里的合起来(重复的算一个),恰好一个才算数。
// 列表里对上的跟歌词文件给的不是同一个时 ok=false:正在放的可能是电台、推荐里同名的另一个版本,点喜欢会收藏错那首(见 02 章决策 270)。
func kuwoFavoriteRID(queue, lyric []int64) (int64, bool) {
	set := map[int64]bool{}
	for _, id := range slices.Concat(queue, lyric) {
		set[id] = true
	}
	if len(set) != 1 {
		return 0, false
	}
	for id := range set {
		return id, true
	}
	return 0, false
}

// kuwoFavoritedIn 当前账号恰好一个「我喜欢听」、认得出这首的 rid 时,看它在不在里面;别的情况 ok=false。
func kuwoFavoritedIn(s kuwoFavoriteSnapshot, lyric []int64) (favorited, ok bool) {
	uid := kuwoCurrentUID(s.users)
	if uid == "" {
		return false, false
	}
	var list int64
	found := 0
	for id, owner := range s.lists {
		if owner == uid {
			list, found = id, found+1
		}
	}
	rid, ridOK := kuwoFavoriteRID(s.queueRIDs, lyric)
	if found != 1 || !ridOK {
		return false, false
	}
	for _, m := range s.members {
		if m[0] == list && m[1] == rid {
			return true, true
		}
	}
	return false, true
}

// kuwoLyricRIDs 歌词目录里「歌手 - 歌名 - rid.lrcx / .lrc」歌手、歌名逐字对上的那几个 rid。
func kuwoLyricRIDs(names []string, artist, title string) []int64 {
	var out []int64
	for _, name := range names {
		a, t, rid, ok := kuwoLocalNamedIdentity(name)
		if !ok || a != strings.TrimSpace(artist) || t != strings.TrimSpace(title) {
			continue
		}
		if v, err := strconv.ParseInt(rid, 10, 64); err == nil {
			out = append(out, v)
		}
	}
	return out
}

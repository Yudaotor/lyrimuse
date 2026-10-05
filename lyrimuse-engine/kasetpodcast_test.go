package main

import (
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
)

// 按 videoId 问 YouTube Music:登记成播客单集的认出来,音轨版本不算,问不成当不是;问成了的记下,再问不发请求。
func TestKasetPodcastEpisode(t *testing.T) {
	resetYtmusicRegionState(t)
	withYTMusicCredits(t, nil)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		if req.target != ytmNextURL {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		switch id, _ := req.body["videoId"].(string); id {
		case "iXucxpIn8fY":
			_, _ = io.WriteString(w, ytmFakeVideoNext(id, ytmusicVideoTypePodcastEpisode))
		case "OsfAnsMY21M":
			_, _ = io.WriteString(w, ytmFakeVideoNext(id, ytmusicVideoTypeATV))
		case "TUVcZfQe-Kw":
			_, _ = io.WriteString(w, ytmFakeVideoNext(id, ytmusicVideoTypeOMV))
		default:
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	})
	if !kasetPodcastEpisode("iXucxpIn8fY") {
		t.Error("登记成播客单集的该认出来")
	}
	if kasetPodcastEpisode("OsfAnsMY21M") {
		t.Error("音轨版本不是播客单集")
	}
	if kasetPodcastEpisode("TUVcZfQe-Kw") {
		t.Error("MV 不是播客单集")
	}
	if kasetPodcastEpisode("Bad0Request") {
		t.Error("问不成当不是")
	}
	failed := len(reqs())
	if kasetPodcastEpisode("Bad0Request") || len(reqs()) != failed {
		t.Errorf("刚没问成的不再问,当不是: %d → %d", failed, len(reqs()))
	}
	n := len(reqs())
	if !kasetPodcastEpisode("iXucxpIn8fY") || len(reqs()) != n {
		t.Errorf("问成了的记下,再问不发请求: %d → %d", n, len(reqs()))
	}
	if !kasetPodcastEpisodeCached("iXucxpIn8fY") || kasetPodcastEpisodeCached("OsfAnsMY21M") || len(reqs()) != n {
		t.Error("轮询路径只看记下的那份")
	}
}

// 接线:待播预取在占位之前跳过播客单集;首次解析的入口挡住已经认出来的播客单集。
func TestKasetPodcastWiring(t *testing.T) {
	up, err := os.ReadFile("upcoming.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(up)
	skip := strings.Index(s, `if t.videoID != "" && kasetPodcastEpisode(t.videoID) {`)
	claim := strings.Index(s, "if !eligible(true) {")
	if skip < 0 || claim < 0 || skip > claim {
		t.Error("待播预取要在占位之前跳过播客单集")
	}
	en, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(en), "if bundleID == kasetBundleID && kasetPodcastEpisodeCached(kasetVideoIDFor(bundleID, artist, title)) {") {
		t.Error("首次解析的入口要挡住认出来的播客单集")
	}
}

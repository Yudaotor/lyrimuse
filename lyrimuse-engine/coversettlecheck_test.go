package main

import (
	"context"
	"image"
	"testing"
	"time"
)

func TestCoverSettleCheckedRecently(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	fresh := now.Add(-24 * time.Hour).Unix()
	member := func(cover, checkedFor string, ts int64) coverSettleMember {
		return coverSettleMember{e: enrichEntry{CoverURL: cover, CoverSettleCheckFor: checkedFor, CoverSettleCheckTS: ts}}
	}
	g := []coverSettleMember{member(settleTux1, settleTux1, fresh), member(settleLegs, settleLegs, fresh)}
	if !coverSettleCheckedRecently(g, now) {
		t.Error("都核过、封面没变、没过期:跳过")
	}
	if coverSettleCheckedRecently([]coverSettleMember{g[0], member(settleLegs, settleTux2, fresh)}, now) {
		t.Error("有一条封面换过:再比")
	}
	if coverSettleCheckedRecently([]coverSettleMember{g[0], g[1], member(settleTux2, "", 0)}, now) {
		t.Error("进来一条新的(没有记号):再比")
	}
	old := now.Add(-coverSettleRecheckInterval).Unix()
	if coverSettleCheckedRecently([]coverSettleMember{g[0], member(settleLegs, settleLegs, old)}, now) {
		t.Error("过了间隔:再比")
	}
}

// 比完定不了的组记下记号:下一遍(取图记忆、Apple 缓存都清空了,同重启)不再取图、不再问 Apple;封面一换就再比。
func TestSettleAlbumCoversRemembersUndecidedGroups(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}, {0, 0}}, nil)
	var fetched []string
	pics := map[string]image.Image{settleTux1: settlePicture(0, false), settleTux2: settlePicture(1, false), settleApple: settlePicture(2, false)}
	asked := withSettleFakes(t, pics, nil)
	coverSweepCoverImage = func(_ context.Context, url string) image.Image {
		fetched = append(fetched, url)
		return pics[url]
	}
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleTux2, CoverSource: "qq", CoverAlbum: "Album"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 0 || settled != 0 {
		t.Fatalf("两张不同的图、Apple 没有这张专辑、没有设备封面:定不了 switched=%d settled=%d", switched, settled)
	}
	enrichMu.Lock()
	for _, k := range []string{"A|a|Album", "A|b|Album"} {
		if e := enrichCache[k]; e.CoverSettleCheckTS == 0 || e.CoverSettleCheckFor != e.CoverURL || coverSettled(e) {
			t.Errorf("%s 该记下定不了的记号、不算定过: %+v", k, e)
		}
	}
	enrichMu.Unlock()
	if len(*asked) == 0 || len(fetched) != 2 {
		t.Fatalf("第一遍要取图、问 Apple: asked=%v fetched=%v", *asked, fetched)
	}

	coverPictureMu.Lock()
	coverPictureMemo = map[string]coverPicture{}
	coverPictureMu.Unlock()
	*asked, fetched = nil, nil
	coverSweepSettleAlbumCovers(context.Background())
	if len(*asked) != 0 || len(fetched) != 0 {
		t.Errorf("封面没变的下一遍不再取图、不问 Apple: asked=%v fetched=%v", *asked, fetched)
	}

	enrichMu.Lock()
	e := enrichCache["A|b|Album"]
	e.CoverURL = settleApple
	enrichCache["A|b|Album"] = e
	enrichMu.Unlock()
	coverSweepSettleAlbumCovers(context.Background())
	if len(fetched) == 0 {
		t.Error("封面换过一条:再比")
	}
}

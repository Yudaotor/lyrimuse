package main

import (
	"context"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 给专辑定封面那一步用的测试封面地址。
const (
	settleLegs  = "file:///art/legs.jpg"
	settleTux1  = "https://p1.music.126.net/tux.jpg"
	settleTux2  = "https://p2.music.126.net/tux.jpg"
	settleApple = "https://is1-ssl.mzstatic.com/image/thumb/tux/1200x1200bb.jpg"
)

// settlePicture:测试用的封面,pattern 画出指纹互相差得很远的几张:0 左亮右暗,1 上亮下暗,2 左上、右下亮,3 只有左上角一小块亮
// (指纹里只有 4 位是 1);letterbox 时上下各补 6 行纯色边(补边的长方形图)。
func settlePicture(pattern int, letterbox bool) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, 32, 32))
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			c := color.RGBA{30, 30, 30, 255}
			switch {
			case letterbox && (y < 6 || y >= 26):
				c = color.RGBA{200, 40, 40, 255}
			case pattern == 0 && x < 16, pattern == 1 && y < 16, pattern == 2 && (x < 16) == (y < 16), pattern == 3 && x < 8 && y < 8:
				c = color.RGBA{230, 230, 230, 255}
			}
			img.Set(x, y, c)
		}
	}
	return img
}

// withSettleFakes:取图按地址给 pics 里那张(没有的取不到);问 Apple 时调 apple(没给就答「问到了、没有」)。返回问过的歌名。
// 要先调 withCoverSweepFakes(它负责还原)。
func withSettleFakes(t *testing.T, pics map[string]image.Image, apple func(title string) (cover, album string, reached bool)) *[]string {
	t.Helper()
	var asked []string
	coverSweepCoverImage = func(_ context.Context, url string) image.Image { return pics[url] }
	coverSweepAppleCover = func(_ context.Context, _, title, _ string, _ float64) (string, string, bool) {
		asked = append(asked, title)
		if apple == nil {
			return "", "", true
		}
		return apple(title)
	}
	return &asked
}

// withProvisional 换一份 enrichProvisional,用例结束还原。
func withProvisional(t *testing.T, m map[string]bool) {
	t.Helper()
	enrichMu.Lock()
	saved := enrichProvisional
	enrichProvisional = m
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichProvisional = saved
		enrichMu.Unlock()
	})
}

// writeSettleJPEG 在临时目录写一张 edge×edge 的 JPEG,返回 file:// 地址(给要读本机文件量尺寸、取图的用例)。
func writeSettleJPEG(t *testing.T, edge int) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, edge, edge))
	for y := 0; y < edge; y++ {
		for x := 0; x < edge; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 255 / edge), uint8(y * 255 / edge), 90, 255})
		}
	}
	path := filepath.Join(t.TempDir(), fmt.Sprintf("cover-%d.jpg", edge))
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(f, img, nil); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return deviceArtworkURLPrefix + path
}

// Off the Wall 那种:设备封面(QQ 音乐那张)跟网易云、Apple 的不是一张图,组里有 Apple 给的 → 定 Apple 那张,地址不是网易云那一份
// 的(设备那几首、同一张图的另一个网易云地址和 Apple 那份)都换成它(地址、来源、专辑、主色;同档的取 key 小的),所有条目记下
// CoverSettled;组里已经有 Apple 的,不再问 Apple。
func TestSettleAlbumCoversFollowsApple(t *testing.T) {
	const album = "Off the Wall"
	for range 10 {
		withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
		asked := withSettleFakes(t, map[string]image.Image{
			settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false), settleTux2: settlePicture(1, false),
			settleApple: settlePicture(1, false),
		}, nil)
		withEnrichCache(t, map[string]enrichEntry{
			"Michael Jackson|Off the Wall|" + album:          {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: album},
			"Michael Jackson|Girlfriend|" + album:            {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: album},
			"Michael Jackson|Rock With You|" + album:         {CoverURL: settleTux2, CoverSource: "netease", CoverAlbum: album, AccentColor: "#222222"},
			"Michael Jackson|Burn This Disco Out|" + album:   {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Off The Wall", AccentColor: "#756252"},
			"Michael Jackson|Working Day And Night|" + album: {CoverURL: settleApple, CoverSource: "apple", CoverAlbum: album},
		})
		enrichMu.Lock()
		enrichDirty = false
		enrichMu.Unlock()
		switched, settled := coverSweepSettleAlbumCovers(context.Background())
		if switched != 4 || settled != 5 {
			t.Fatalf("记下 %d 条、换了 %d 条, 要 5、4", settled, switched)
		}
		if len(*asked) != 0 {
			t.Errorf("组里有 Apple 给的封面,不该再问: %v", *asked)
		}
		enrichMu.Lock()
		for _, title := range []string{"Off the Wall", "Girlfriend"} {
			e := enrichCache["Michael Jackson|"+title+"|"+album]
			if e.CoverURL != settleTux1 || e.CoverSource != "netease" || e.CoverAlbum != "Off The Wall" || e.AccentColor != "#756252" || !coverSettled(e) {
				t.Errorf("%s 该换成网易云 key 小的那一份并定下: %+v", title, e)
			}
		}
		for _, title := range []string{"Rock With You", "Burn This Disco Out", "Working Day And Night"} {
			if e := enrichCache["Michael Jackson|"+title+"|"+album]; e.CoverURL != settleTux1 || e.CoverSource != "netease" || !coverSettled(e) {
				t.Errorf("%s 跟定下的是同一张图,也统一成那一份: %+v", title, e)
			}
		}
		if !enrichDirty {
			t.Error("定下了要置脏")
		}
		enrichMu.Unlock()
	}
}

// Apple 那张跟设备封面是同一张图:网易云那几首换成设备那一份;组里没有 Apple 给的封面,按 key 顺序拿第一首去问,答到了就不再问。
func TestSettleAlbumCoversAsksAppleAndKeepsTheDeviceCover(t *testing.T) {
	const album = "完美的一天"
	for range 10 {
		withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
		asked := withSettleFakes(t, map[string]image.Image{
			settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false), settleApple: settlePicture(0, false),
		}, func(string) (string, string, bool) { return settleApple, album, true })
		withEnrichCache(t, map[string]enrichEntry{
			"孙燕姿|完美的一天|" + album: {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: album},
			"孙燕姿|一天|" + album:    {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: album},
			"孙燕姿|遇见|" + album:    {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: album},
		})
		switched, settled := coverSweepSettleAlbumCovers(context.Background())
		if switched != 2 || settled != 3 {
			t.Fatalf("记下 %d 条、换了 %d 条, 要 3、2", settled, switched)
		}
		if len(*asked) != 1 || (*asked)[0] != "一天" {
			t.Errorf("问了 %v, 要只问 key 最小的那首", *asked)
		}
		enrichMu.Lock()
		for _, title := range []string{"一天", "遇见", "完美的一天"} {
			if e := enrichCache["孙燕姿|"+title+"|"+album]; e.CoverURL != settleLegs || e.CoverSource != "device" || e.CoverAlbum != album || !coverSettled(e) {
				t.Errorf("%s 该定成设备那张: %+v", title, e)
			}
		}
		enrichMu.Unlock()
	}
}

// 各首都是同一张图(网易云那份跟设备封面一样):不问 Apple,地址不是网易云那一份的换成它,都定下(各家版本色调、裁切不同,
// 按图比算同一张,统一成一个地址才看着一样)。见 03 章决策 52。
func TestSettleAlbumCoversSamePictureOneAddress(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	asked := withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(0, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
		"A|c|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 1 || settled != 3 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要 3、1", settled, switched)
	}
	if len(*asked) != 0 {
		t.Errorf("同一张图不用问 Apple: %v", *asked)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, key := range []string{"A|a|Album", "A|b|Album", "A|c|Album"} {
		if e := enrichCache[key]; e.CoverURL != settleTux1 || !coverSettled(e) {
			t.Errorf("%s 该统一成网易云那一份并定下: %+v", key, e)
		}
	}
}

// Apple 没有这张专辑(两首都问了,第二次之前隔 coverSweepAppleGap)、给的是第三张图、给的专辑对不上:都定设备封面那张。
func TestSettleAlbumCoversFallsBackToTheDeviceCover(t *testing.T) {
	for _, c := range []struct {
		name  string
		apple func(string) (string, string, bool)
		asked int
	}{
		{"没有这张专辑", func(string) (string, string, bool) { return "", "", true }, 2},
		{"第三张图", func(string) (string, string, bool) { return settleApple, "Album", true }, 1},
		{"专辑对不上", func(string) (string, string, bool) { return settleApple, "Thriller", true }, 2},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, waits := withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
			asked := withSettleFakes(t, map[string]image.Image{
				settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false), settleApple: settlePicture(2, false),
			}, c.apple)
			withEnrichCache(t, map[string]enrichEntry{
				"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
				"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
			})
			if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 1 || settled != 2 {
				t.Fatalf("记下 %d 条、换了 %d 条, 要 2、1", settled, switched)
			}
			enrichMu.Lock()
			e := enrichCache["A|a|Album"]
			enrichMu.Unlock()
			if e.CoverURL != settleLegs || e.CoverSource != "device" || !coverSettled(e) {
				t.Errorf("该定成设备封面那张: %+v", e)
			}
			if len(*asked) != c.asked {
				t.Errorf("问了 %v, 要 %d 次", *asked, c.asked)
			}
			if want := c.asked - 1; len(*waits) != want || (want == 1 && (*waits)[0] != coverSweepAppleGap) {
				t.Errorf("等待 %v, 要 %d 次 coverSweepAppleGap", *waits, want)
			}
		})
	}
}

// Apple 没有这张专辑时,别把「没有」当成一张图去比:组里有一张几乎全暗的封面(指纹只有几位是 1)也照样定设备那张。
func TestSettleAlbumCoversDoesNotMatchAMissingApplePicture(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(3, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	coverSweepSettleAlbumCovers(context.Background())
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, key := range []string{"A|a|Album", "A|b|Album"} {
		if e := enrichCache[key]; e.CoverURL != settleLegs || !coverSettled(e) {
			t.Errorf("%s 该定成设备那张: %+v", key, e)
		}
	}
}

// 组里 Apple 给的那张专辑对不上(Apple 把这首挂在别的专辑上):不当 Apple 的答案,照样去问。
func TestSettleAlbumCoversIgnoresAnAppleCoverOfAnotherAlbum(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	asked := withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false),
		settleApple: settlePicture(1, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
		"A|c|Album": {CoverURL: settleApple, CoverSource: "apple", CoverAlbum: "Thriller"},
	})
	coverSweepSettleAlbumCovers(context.Background())
	if len(*asked) == 0 {
		t.Error("组里 Apple 那张专辑对不上,该再问 Apple")
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|a|Album"]; e.CoverURL != settleLegs {
		t.Errorf("Apple 没给出这张专辑,该定设备那张: %+v", e)
	}
}

// Apple 没问到:这一遍不定(不能当成「Apple 没有」退回设备封面),下一遍再来。
func TestSettleAlbumCoversWaitsWhenAppleIsUnreached(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false)},
		func(string) (string, string, bool) { return "", "", false })
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 0 || settled != 0 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要都是 0", settled, switched)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|a|Album"]; e.CoverURL != settleTux1 || e.CoverSettled != "" {
		t.Errorf("没问到 Apple 不该动: %+v", e)
	}
}

// Apple 给的那张图取不到:同上,这一遍不定。
func TestSettleAlbumCoversWaitsWhenApplesPictureIsUnreached(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false)},
		func(string) (string, string, bool) { return settleApple, "Album", true })
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 0 || settled != 0 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要都是 0", settled, switched)
	}
}

// key 最小那条设备封面是补边的长方形图、Apple 又没有这张专辑:不定(不往后找别的设备封面)。
func TestSettleAlbumCoversLeavesALetterboxedDeviceCoverUndecided(t *testing.T) {
	if !coverContentLetterboxed(settlePicture(0, true)) {
		t.Fatal("用例前提:测试图该是补边的")
	}
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	const other = "file:///art/other.jpg"
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, true), settleTux1: settlePicture(1, false),
		other: settlePicture(2, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
		"A|c|Album": {CoverURL: other, CoverSource: "device", CoverAlbum: "Album"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 0 || settled != 0 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要都是 0", settled, switched)
	}
}

// 之前定过的专辑:新来的设备封面换成定下的那张,不问 Apple;已经定下的不重记。
func TestSettleAlbumCoversFollowsAnEarlierSettlement(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	asked := withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album", CoverSettled: settleTux1},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 1 || settled != 1 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要 1、1", settled, switched)
	}
	if len(*asked) != 0 {
		t.Errorf("定过的专辑不用问 Apple: %v", *asked)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["A|b|Album"]; e.CoverURL != settleTux1 || e.CoverSource != "netease" || !coverSettled(e) {
		t.Errorf("新来的该照定下的那张: %+v", e)
	}
}

// 定过的专辑里没有设备封面了(都换成了定下的那张),新来的别的来源的封面照样照定下的那张办。
func TestSettleAlbumCoversSettlesStragglers(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	const qq = "https://y.qq.com/music/photo_new/T002R800x800M000x.jpg"
	withSettleFakes(t, map[string]image.Image{settleTux1: settlePicture(1, false), qq: settlePicture(2, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album", CoverSettled: settleTux1},
		"A|b|Album": {CoverURL: qq, CoverSource: "qq", CoverAlbum: "Album"},
	})
	if switched, _ := coverSweepSettleAlbumCovers(context.Background()); switched != 1 {
		t.Fatalf("换了 %d 条, 要 1", switched)
	}
}

// 已经全部定下的专辑不再取图。
func TestSettleAlbumCoversSkipsSettledAlbums(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	calls := 0
	coverSweepCoverImage = func(context.Context, string) image.Image {
		calls++
		return settlePicture(1, false)
	}
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	if _, settled := coverSweepSettleAlbumCovers(context.Background()); settled != 2 {
		t.Fatalf("第一遍记下 %d 条, 要 2", settled)
	}
	coverPictureMu.Lock()
	coverPictureMemo = map[string]coverPicture{}
	coverPictureMu.Unlock()
	calls = 0
	coverSweepSettleAlbumCovers(context.Background())
	if calls != 0 {
		t.Errorf("全部定下的专辑又取了 %d 次图", calls)
	}
}

// 组里有一张图取不到:这一遍不定这一组,别的组照定;连着 coverSweepOfflineLimit 组都这样就停,中间有一组定成了就重新数。
func TestSettleAlbumCoversSkipsGroupsWithUnloadablePictures(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(0, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Gone": {CoverURL: "https://p1.music.126.net/gone.jpg", CoverSource: "netease", CoverAlbum: "Gone"},
		"A|b|Gone": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Gone"},
		"A|a|Here": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Here"},
		"A|b|Here": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Here"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 1 || settled != 2 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要 2、1", settled, switched)
	}
	enrichMu.Lock()
	if e := enrichCache["A|a|Gone"]; e.CoverSettled != "" {
		t.Errorf("图取不到的那组不该定: %+v", e)
	}
	enrichMu.Unlock()

	// albums 里 g、i 开头的那组取不到图,别的取得到;按 key 排着一组组来。
	run := func(albums []string) (tried, settled int) {
		cache := map[string]enrichEntry{}
		for i, album := range albums {
			url := settleTux1
			if strings.HasPrefix(album, "g") || strings.HasPrefix(album, "i") {
				url = fmt.Sprintf("https://p1.music.126.net/gone%d.jpg", i)
			}
			cache["A|a|"+album] = enrichEntry{CoverURL: url, CoverSource: "netease", CoverAlbum: album}
			cache["A|b|"+album] = enrichEntry{CoverURL: settleLegs, CoverSource: "device", CoverAlbum: album}
		}
		withEnrichCache(t, cache)
		coverSweepCoverImage = func(_ context.Context, url string) image.Image {
			if strings.Contains(url, "/gone") {
				tried++
				return nil
			}
			return settlePicture(0, false)
		}
		_, settled = coverSweepSettleAlbumCovers(context.Background())
		return tried, settled
	}
	for range 10 {
		var albums []string
		for i := range coverSweepOfflineLimit + 2 {
			albums = append(albums, fmt.Sprintf("g%d", i))
		}
		if tried, settled := run(append(albums, "zz")); settled != 0 || tried != coverSweepOfflineLimit {
			t.Fatalf("记下 %d 条、试了 %d 组, 要 0 条、%d 组就停", settled, tried, coverSweepOfflineLimit)
		}
	}
	var albums []string
	for i := range coverSweepOfflineLimit - 1 {
		albums = append(albums, fmt.Sprintf("g%d", i))
	}
	albums = append(albums, "h")
	for i := range coverSweepOfflineLimit - 1 {
		albums = append(albums, fmt.Sprintf("i%d", i))
	}
	if _, settled := run(append(albums, "zz")); settled != 4 {
		t.Errorf("中间那组定成了就重新数,后面的照定: 记下 %d 条, 要 4", settled)
	}
}

// 取图、问 Apple 那段时间里条目被改了(封面换了、被占去解析、成了提前提交的):不写它,别的照写。
func TestSettleAlbumCoversSkipsEntriesChangedMeanwhile(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withProvisional(t, map[string]bool{})
	withSettleFakes(t, map[string]image.Image{
		settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false), settleApple: settlePicture(0, false),
	}, func(string) (string, string, bool) {
		enrichMu.Lock()
		e := enrichCache["A|a|Album"]
		e.CoverURL = settleTux2
		enrichCache["A|a|Album"] = e
		enrichInflight["A|b|Album"] = true
		enrichProvisional["A|e|Album"] = true
		enrichMu.Unlock()
		return settleApple, "Album", true
	})
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|c|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|d|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
		"A|e|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 1 || settled != 2 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要 2、1", settled, switched)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for key, url := range map[string]string{"A|a|Album": settleTux2, "A|b|Album": settleTux1, "A|e|Album": settleTux1} {
		if e := enrichCache[key]; e.CoverURL != url || e.CoverSettled != "" {
			t.Errorf("%s 期间被改过,不该写: %+v", key, e)
		}
	}
	if e := enrichCache["A|c|Album"]; e.CoverURL != settleLegs || !coverSettled(e) {
		t.Errorf("没被改过的照写: %+v", e)
	}
}

// 正在解析、提前提交的条目不进组:它们的封面不参与比,同一张图的专辑不会因为它们去问 Apple。
func TestSettleAlbumCoversLeavesOutResolvingEntries(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withProvisional(t, map[string]bool{"A|c|Album": true})
	asked := withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(0, false),
		settleTux2: settlePicture(2, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
		"A|c|Album": {CoverURL: settleTux2, CoverSource: "netease", CoverAlbum: "Album"},
		"A|d|Album": {CoverURL: settleTux2, CoverSource: "netease", CoverAlbum: "Album"},
	})
	enrichMu.Lock()
	enrichInflight["A|d|Album"] = true
	enrichMu.Unlock()
	if _, settled := coverSweepSettleAlbumCovers(context.Background()); settled != 2 {
		t.Fatalf("记下 %d 条, 要 2", settled)
	}
	if len(*asked) != 0 {
		t.Errorf("解析中的条目不该让同一张图的专辑去问 Apple: %v", *asked)
	}
}

// 有别的歌在解析时先等它解析完,再给专辑定封面。
func TestSettleAlbumCoversYieldsToResolvingEntries(t *testing.T) {
	_, waits := withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	enrichMu.Lock()
	enrichInflight["B|playing|X"] = true
	enrichMu.Unlock()
	coverSweepWait = func(_ context.Context, d time.Duration) {
		*waits = append(*waits, d)
		enrichMu.Lock()
		delete(enrichInflight, "B|playing|X")
		enrichMu.Unlock()
	}
	coverSweepCoverImage = func(context.Context, string) image.Image {
		enrichMu.Lock()
		busy := len(enrichInflight) > 0
		enrichMu.Unlock()
		if busy {
			t.Error("还有歌在解析就去取图了")
		}
		return settlePicture(1, false)
	}
	if _, settled := coverSweepSettleAlbumCovers(context.Background()); settled != 2 || len(*waits) != 1 || (*waits)[0] != coverSweepYieldPoll {
		t.Errorf("记下 %d 条, 等待 %v", settled, *waits)
	}
}

// 进程要退出(ctx 取消):不再定(同一张图、不用问 Apple 的那种也不定);问 Apple 之前那段间隔里取消的,那一组也不定。
func TestSettleAlbumCoversStopsWhenCancelled(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(0, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, settled := coverSweepSettleAlbumCovers(ctx); settled != 0 {
		t.Errorf("取消了还记下 %d 条", settled)
	}
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(1, false)}, nil)
	coverPictureMu.Lock()
	coverPictureMemo = map[string]coverPicture{}
	coverPictureMu.Unlock()
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	coverSweepWait = func(context.Context, time.Duration) { cancel() }
	if _, settled := coverSweepSettleAlbumCovers(ctx); settled != 0 {
		t.Errorf("问 Apple 之前取消了还记下 %d 条", settled)
	}
}

// 分组:不同歌手的同名专辑分开定,繁简写法不同的同一张专辑算一组;只有一个地址的组不定。没有核实过的设备封面、也没定过的组
// 照样定:各首其实是同一张图就定它,不是同一张图时 Apple 目录的封面跟其中一张是同一张图就定那张,对不上的不定。见 03 章决策 52。
func TestSettleAlbumCoversGroups(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	const (
		other1 = "https://y.qq.com/music/photo_new/T002R800x800M000other1.jpg"
		other2 = "https://y.qq.com/music/photo_new/T002R800x800M000other2.jpg"
		odd    = "https://y.qq.com/music/photo_new/T002R800x800M000odd.jpg"
	)
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(0, false),
		settleTux2: settlePicture(0, false), settleApple: settlePicture(1, false), other1: settlePicture(1, false),
		other2: settlePicture(2, false), odd: settlePicture(3, false)},
		func(title string) (string, string, bool) {
			if title == "apple" {
				return settleApple, "Picked", true
			}
			return "", "", true
		})
	withEnrichCache(t, map[string]enrichEntry{
		"陈奕迅|a|国语精选":     {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "国语精选"},
		"陈奕迅|b|國語精選":     {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "國語精選"},
		"别人|a|国语精选":      {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "国语精选"},
		"别人|b|国语精选":      {CoverURL: settleTux2, CoverSource: "netease", CoverAlbum: "国语精选"},
		"C|a|Solo":       {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Solo"},
		"C|b|Solo":       {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Solo"},
		"E|apple|Picked": {CoverURL: other1, CoverSource: "qq", CoverAlbum: "Picked"},
		"E|b|Picked":     {CoverURL: other2, CoverSource: "qq", CoverAlbum: "Picked"},
		"F|a|Loose":      {CoverURL: other2, CoverSource: "qq", CoverAlbum: "Loose"},
		"F|b|Loose":      {CoverURL: odd, CoverSource: "qq", CoverAlbum: "Loose"},
	})
	switched, settled := coverSweepSettleAlbumCovers(context.Background())
	if switched != 3 || settled != 6 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要 6、3", settled, switched)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, key := range []string{"陈奕迅|a|国语精选", "陈奕迅|b|國語精選", "别人|a|国语精选", "别人|b|国语精选", "E|apple|Picked", "E|b|Picked"} {
		if !coverSettled(enrichCache[key]) {
			t.Errorf("%s 该定下", key)
		}
	}
	if e := enrichCache["E|b|Picked"]; e.CoverURL != other1 {
		t.Errorf("没有核实过的设备封面:跟 Apple 那张是同一张图的定下,别的换成它: %+v", e)
	}
	for _, key := range []string{"C|a|Solo", "C|b|Solo", "F|a|Loose", "F|b|Loose"} {
		if enrichCache[key].CoverSettled != "" {
			t.Errorf("%s 不该定", key)
		}
	}
}

// 给要换的条目挑哪一份:网易云、够清晰的设备封面、别的 https、其余(小设备封面、播放器的本机文件)。
func TestCoverSettleRank(t *testing.T) {
	big, small := writeSettleJPEG(t, 320), writeSettleJPEG(t, 120)
	for _, c := range []struct {
		e    enrichEntry
		want int
	}{
		{enrichEntry{CoverURL: settleTux1, CoverSource: "netease"}, 0},
		{enrichEntry{CoverURL: big, CoverSource: "device"}, 1},
		{enrichEntry{CoverURL: settleApple, CoverSource: "apple"}, 2},
		{enrichEntry{CoverURL: "https://y.qq.com/x.jpg", CoverSource: "qq"}, 2},
		{enrichEntry{CoverURL: small, CoverSource: "device"}, 3},
		{enrichEntry{CoverURL: "file:///x/player.jpg", CoverSource: "player"}, 3},
	} {
		if got := coverSettleRank(c.e); got != c.want {
			t.Errorf("%s %s: %d, 要 %d", c.e.CoverSource, c.e.CoverURL, got, c.want)
		}
	}
}

// 一遍跑下来,给专辑定封面那一步排在补封面前面几步之后:换了封面的存一次盘,只记下了定下的(没换封面)也存。
func TestRunCoverSweepSettlesAlbumCovers(t *testing.T) {
	for _, c := range []struct {
		name      string
		netease   image.Image
		withApple bool
		want      string
	}{
		{"换成 Apple 那张", settlePicture(1, false), true, settleTux1},
		{"同一张图统一成网易云那一份", settlePicture(0, false), false, settleTux1},
	} {
		t.Run(c.name, func(t *testing.T) {
			withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
			saves := 0
			coverSweepSave = func() { saves++ }
			withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: c.netease,
				settleApple: settlePicture(1, false)}, nil)
			cache := map[string]enrichEntry{
				"A|a|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album", Lyrics: coverSweepLyrics},
				"A|b|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album", Lyrics: coverSweepLyrics},
			}
			if c.withApple {
				cache["A|c|Album"] = enrichEntry{CoverURL: settleApple, CoverSource: "apple", CoverAlbum: "Album", Lyrics: coverSweepLyrics}
			}
			withEnrichCache(t, cache)
			runCoverSweep(context.Background())
			enrichMu.Lock()
			e := enrichCache["A|a|Album"]
			enrichMu.Unlock()
			if e.CoverURL != c.want || !coverSettled(e) {
				t.Errorf("该定成 %s: %+v", c.want, e)
			}
			if saves != 1 {
				t.Errorf("存了 %d 次盘, 要 1 次", saves)
			}
		})
	}
}

// 定下的封面别处不再换:外围补全的换封面闸、借同专辑封面、按专辑复查、另一张专辑的判定都放过它;封面被别处换过,定下的
// 那条记录就不算数。照定下的那张取的新结果换得上,旧的是播放器自带的封面也换。
func TestSettledCoverIsKept(t *testing.T) {
	const album = "Off the Wall"
	settled := enrichEntry{CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Off the Wall (Special Edition)", CoverSettled: settleTux1}
	if !coverSettled(settled) {
		t.Fatal("定下的该认")
	}
	lapsed := settled
	lapsed.CoverURL = settleTux2
	if coverSettled(lapsed) {
		t.Error("封面换过,定下的记录不算数")
	}
	if coverSettled(enrichEntry{CoverSettled: ""}) {
		t.Error("没封面的不算定下")
	}
	if coverSwapAllowed(settled, enrichEntry{CoverURL: settleLegs, CoverSource: "device", CoverAlbum: album}, album) {
		t.Error("定下的不该被换掉")
	}
	player := enrichEntry{CoverURL: "https://i.kfs.io/album/x/fit/1000x1000.jpg", CoverSource: "player", CoverAlbum: album}
	fresh := enrichEntry{CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: album, CoverSettled: settleTux1}
	if !coverSwapAllowed(player, fresh, album) {
		t.Error("照定下的那张取的该换得上")
	}
	fresh.CoverSettled = ""
	if coverSwapAllowed(player, fresh, album) {
		t.Error("对照:没定下的换不掉播放器自带的")
	}
	qq := enrichEntry{CoverURL: "https://y.qq.com/x.jpg", CoverSource: "qq", CoverAlbum: "Bad"}
	settledQQ := qq
	settledQQ.CoverSettled = qq.CoverURL
	if !coverAwaitsVerifiedSibling(qq, album) || coverAwaitsVerifiedSibling(settledQQ, album) {
		t.Error("借同专辑封面:没定下的照借,定下的不借")
	}
	if !coverOfAnotherAlbum(qq, album) || coverOfAnotherAlbum(settledQQ, album) {
		t.Error("另一张专辑的判定:没定下的照判,定下的放过")
	}
	unsettled := settled
	unsettled.CoverSettled = ""
	if !coverNeedsAlbumCheck(unsettled, album) || coverNeedsAlbumCheck(settled, album) {
		t.Error("按专辑复查:没定下的照查,定下的不查")
	}
}

// 设备封面不顶定下的封面(在取图比对之前就返回)。
func TestApplyDeviceOrPlayerCoverKeepsSettledCover(t *testing.T) {
	savedPublic := devicePublicCover
	devicePublicCover = func(context.Context, string, string) string { return "" }
	t.Cleanup(func() { devicePublicCover = savedPublic })
	device := writeSettleJPEG(t, 320)
	e := enrichEntry{CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album", CoverSettled: settleTux1}
	applyDeviceOrPlayerCover(context.Background(), &e, device, "Album")
	if e.CoverURL != settleTux1 || e.CoverSource != "netease" {
		t.Errorf("设备封面不该顶掉定下的: %+v", e)
	}
	e.CoverSettled = ""
	applyDeviceOrPlayerCover(context.Background(), &e, device, "Album")
	if e.CoverURL != device {
		t.Errorf("对照:没定下的照顶: %+v", e)
	}
}

// settledAlbumCover:同歌手、专辑名繁简折叠后相同的条目里,取 key 最小那条定下的;封面换过的、别的歌手的不算;没专辑不取。
func TestSettledAlbumCover(t *testing.T) {
	for range 20 {
		withEnrichCache(t, map[string]enrichEntry{
			"陈奕迅|a|陈奕迅 国语精选": {CoverURL: settleLegs, CoverSource: "device", CoverSettled: "file:///old.jpg"},
			"陈奕迅|b|陈奕迅 国语精选": {CoverURL: settleTux2, CoverSource: "netease", CoverAlbum: "陈奕迅 国语精选", CoverSettled: settleTux2},
			"陈奕迅|c|陳奕迅 國語精選": {CoverURL: settleTux1, CoverSource: "netease", CoverSettled: settleTux1},
			"别人|0|陈奕迅 国语精选":  {CoverURL: settleApple, CoverSource: "apple", CoverSettled: settleApple},
			"陈奕迅|x|":         {CoverURL: settleApple, CoverSource: "apple", CoverSettled: settleApple},
		})
		for _, album := range []string{"陈奕迅 国语精选", "陳奕迅 國語精選"} {
			if e, ok := settledAlbumCover("陈奕迅", album); !ok || e.CoverURL != settleTux2 || e.CoverAlbum != "陈奕迅 国语精选" {
				t.Fatalf("%s: 该取 key 最小那条定下的: %+v %v", album, e, ok)
			}
		}
		if _, ok := settledAlbumCover("陈奕迅", ""); ok {
			t.Fatal("没专辑不取")
		}
		if _, ok := settledAlbumCover("陈奕迅", "别的专辑"); ok {
			t.Fatal("别的专辑不取")
		}
	}
}

// 定下的封面接到放歌时取设备封面、首次 / 重新解析、外围补全几条路上(这几段在 trackEnrichment / resolveTrackEnrichment /
// backfillPeripheralFields 里,功能测试搭不起来)。
func TestSettledCoverIsWired(t *testing.T) {
	src := string(mustRead(t, "enrich.go"))
	for _, n := range []string{
		"if isNewTrack && e.CoverSource != \"device\" && e.CoverSource != \"player\" && !coverSettled(e) && !enrichInflight[key] {",
		"if !exists || provisional || existing.CoverURL == deviceCoverURL || coverSettled(existing) {",
		"if !ok || enrichProvisional[key] || e.CoverURL == cover || coverSettled(e) {",
		"if s, ok := settledAlbumCover(lookupArtist, listedAlbum); ok {\n\t\te.CoverURL, e.CoverSource, e.CoverAlbum, e.CoverSettled = s.CoverURL, s.CoverSource, s.CoverAlbum, s.CoverURL\n\t}\n\tif deviceCoverURL == \"\" {",
		"listedAlbum := coverAlbum\n\tif listedAlbum == \"\" {\n\t\tlistedAlbum = strings.TrimSpace(e.YouTubeMusicAlbum)\n\t}\n\tif coverAlbum == \"\" {\n\t\tcoverAlbum = appleAlbumHintSync(",
		"e.CoverURL, e.CoverSource, e.CoverAlbum, e.AccentColor, e.CoverSettled =\n\t\t\tfresh.CoverURL, fresh.CoverSource, fresh.CoverAlbum, fresh.AccentColor, fresh.CoverSettled",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}

// 问没问到 Apple:命中缓存、真的查空、在负缓存窗口里、没歌名都算问到了;被限流时 reached 为 false(空结果不说明 Apple 没有)。
func TestAppleMusicMatchCachedReached(t *testing.T) {
	resetAppleMatchCaches(t)
	resetITunesSearchBackoff(t)
	limited := false
	withFakeITunes(t, func(w http.ResponseWriter, r *http.Request) {
		if limited {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"results":[]}`))
	})
	ctx := context.Background()
	appleURLMu.Lock()
	appleURLCache["有|这首|专辑"] = appleMusicMatch{url: "https://music.apple.com/x", cover: "https://a/c.jpg"}
	appleURLMu.Unlock()
	if m, reached := appleMusicMatchCachedReached(ctx, "有", "这首", "专辑", 0); m.cover != "https://a/c.jpg" || !reached {
		t.Errorf("命中缓存该算问到了: %+v %v", m, reached)
	}
	for i, what := range []string{"真的查空", "负缓存窗口里"} {
		if m, reached := appleMusicMatchCachedReached(ctx, "查无此人", "查无此曲", "查无此辑", 0); m.cover != "" || !reached {
			t.Errorf("第 %d 次(%s)该算问到了: %+v %v", i+1, what, m, reached)
		}
	}
	if _, reached := appleMusicMatchCachedReached(ctx, "某歌手", "", "某专辑", 0); !reached {
		t.Error("没歌名不用问,算问到了")
	}
	limited = true
	if _, reached := appleMusicMatchCachedReached(ctx, "被限流", "某首歌", "某专辑", 0); reached {
		t.Error("被限流不算问到")
	}
}

// 给专辑定封面那一步取图走后台出站、按地址记着:同一个地址这一遍只取一次。
func TestCoverSweepPictureIsRemembered(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	calls, background := 0, true
	coverSweepCoverImage = func(ctx context.Context, url string) image.Image {
		calls++
		background = background && isBackgroundOutbound(ctx)
		return settlePicture(1, false)
	}
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|b|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"A|c|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
		"B|a|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album"},
		"B|c|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album"},
	})
	coverSweepSettleAlbumCovers(context.Background())
	if calls != 2 || !background {
		t.Errorf("取了 %d 次(要 2 次,两个地址各一次),走后台出站 %v", calls, background)
	}
}

// 都定过、地址仍不止一个的组(先前同一张图各留各的地址):再定一次,统一成网易云那一份。见 03 章决策 52。
func TestSettleAlbumCoversReunifiesSettledGroups(t *testing.T) {
	withCoverSweepFakes(t, [][2]int32{{0, 0}}, nil)
	withSettleFakes(t, map[string]image.Image{settleLegs: settlePicture(0, false), settleTux1: settlePicture(0, false)}, nil)
	withEnrichCache(t, map[string]enrichEntry{
		"A|a|Album": {CoverURL: settleLegs, CoverSource: "device", CoverAlbum: "Album", CoverSettled: settleLegs},
		"A|b|Album": {CoverURL: settleTux1, CoverSource: "netease", CoverAlbum: "Album", CoverSettled: settleTux1},
	})
	if switched, settled := coverSweepSettleAlbumCovers(context.Background()); switched != 1 || settled != 1 {
		t.Fatalf("记下 %d 条、换了 %d 条, 要 1、1", settled, switched)
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	for _, key := range []string{"A|a|Album", "A|b|Album"} {
		if e := enrichCache[key]; e.CoverURL != settleTux1 || !coverSettled(e) {
			t.Errorf("%s 该统一成网易云那一份并定下: %+v", key, e)
		}
	}
}

package main

import (
	"image"
	"image/color"
	"testing"
)

// 合成一张有结构的图:左上到右下的渐变 + 几个方块,缩放之后指纹稳定。
// scale 只改分辨率、不改内容 —— 用来验"同一张图不同分辨率"这一档。
func synthCover(edge int, seed int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, edge, edge))
	for y := 0; y < edge; y++ {
		for x := 0; x < edge; x++ {
			// 归一化坐标,保证内容跟 edge 无关
			fx := float64(x) / float64(edge)
			fy := float64(y) / float64(edge)
			v := 40 + 180*fx*fy
			// seed 决定方块摆在哪,不同 seed = 不同封面
			if int(fx*4)+int(fy*4)+seed%3 == seed%5 {
				v = 250 - v
			}
			if seed%2 == 1 && fx > 0.6 && fy < 0.4 {
				v = 255 - v
			}
			c := uint8(v)
			img.Set(x, y, color.RGBA{R: c, G: c / 2, B: 255 - c, A: 255})
		}
	}
	return img
}

func solidCover(edge int, v uint8) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, edge, edge))
	for y := 0; y < edge; y++ {
		for x := 0; x < edge; x++ {
			img.Set(x, y, color.RGBA{R: v, G: v, B: v, A: 255})
		}
	}
	return img
}

// 指纹的核心性质:同一张图换分辨率不该改变指纹(这条不成立整个判据就没意义)。
func TestCoverFingerprintStableAcrossScale(t *testing.T) {
	base := coverFingerprint(synthCover(64, 1))
	for _, edge := range []int{80, 120, 300, 800, 1400} {
		got := coverFingerprint(synthCover(edge, 1))
		if d := coverFingerprintDistance(base, got); d > coverFingerprintMaxDistance {
			t.Errorf("同一张图 %dpx 版的指纹距离 64px 版 = %d,超过阈值 %d", edge, d, coverFingerprintMaxDistance)
		}
	}
	// 不同内容要分得开。
	other := coverFingerprint(synthCover(800, 4))
	if d := coverFingerprintDistance(base, other); d <= coverFingerprintMaxDistance {
		t.Errorf("两张不同的图距离只有 %d,阈值 %d 分不开", d, coverFingerprintMaxDistance)
	}
}

func TestCoverImagesLikelySame(t *testing.T) {
	if !coverImagesLikelySame(synthCover(120, 1), synthCover(800, 1)) {
		t.Error("同一张图的两个分辨率该判成同一张")
	}
	if coverImagesLikelySame(synthCover(120, 1), synthCover(800, 4)) {
		t.Error("两张不同的图不该判成同一张")
	}
	// nil 与退化指纹(纯色图)不能被当成"跟谁都一样" —— 那会让判据变成"总是换成远程"。
	if coverImagesLikelySame(nil, synthCover(120, 1)) || coverImagesLikelySame(synthCover(120, 1), nil) {
		t.Error("nil 不该判成同一张")
	}
	if coverImagesLikelySame(solidCover(120, 128), solidCover(800, 200)) {
		t.Error("纯色图指纹退化成全 0,不该被当成同一张")
	}
}

// URL 尺寸解析 —— 这条是"候选是不是更大"的唯一依据,解错了整条判据跟着错。
func TestCoverURLIntendedEdge(t *testing.T) {
	cases := []struct {
		url  string
		want int
	}{
		// 网易云:真实形态(本机缓存里就是这个)
		{"https://p2.music.126.net/O0rm==/109951166232338422.jpg?param=800y800", 800},
		{"https://p1.music.126.net/abc==/123.jpg?param=64y64", 64},
		{"https://p1.music.126.net/abc==/123.jpg?param=300x300", 300},
		{"https://p1.music.126.net/abc==/123.jpg?param=800y800&foo=1", 800},
		// Apple mzstatic
		{"https://is1-ssl.mzstatic.com/image/thumb/abc/600x600bb.jpg", 600},
		// QQ:尺寸档在路径里
		{"https://y.qq.com/music/photo_new/T002R800x800M000abc.jpg", 800},
		// 认不出来 → 0,调用方保守保留设备封面
		{"https://example.com/cover.jpg", 0},
		{"", 0},
		{"file:///Users/x/.config/lyrimuse/artwork/5b8fe093a7f81d31.jpg", 0},
		// 非正方形档位不该被当成尺寸(避免把随便一个 12x34 读成尺寸)
		{"https://example.com/a/12x34/cover.jpg", 0},
	}
	for _, c := range cases {
		if got := coverURLIntendedEdge(c.url); got != c.want {
			t.Errorf("coverURLIntendedEdge(%q) = %d, want %d", c.url, got, c.want)
		}
	}
}

// 判据表逐档。这是整个修复的核心,每一档都得钉住 —— 尤其"不一样就保留设备封面"那档,
// 它是 Immortal 那个 bug 不复发的唯一保证。
func TestDeviceCoverDecision(t *testing.T) {
	const neteaseBig = "https://p1.music.126.net/abc==/1.jpg?param=800y800"
	load := func(img image.Image) func(string) image.Image {
		return func(string) image.Image { return img }
	}
	neverLoad := func(string) image.Image {
		t.Error("这一档不该发起取图")
		return nil
	}

	// ① 设备封面够清晰 → 直接顶掉,且**不取图**(快路径)
	if ov, why := deviceCoverDecision(synthCover(600, 1), neteaseBig, 800, neverLoad); !ov {
		t.Errorf("够清晰的设备封面该顶掉候选, why=%s", why)
	}
	// 边界:正好等于门槛也算够清晰
	if ov, _ := deviceCoverDecision(synthCover(deviceCoverTrustedMinEdge, 1), neteaseBig, 800, neverLoad); !ov {
		t.Error("边长正好等于门槛该算够清晰")
	}

	// ② 没有远程候选 → 顶掉(没有更好的选择),不取图
	if ov, _ := deviceCoverDecision(synthCover(120, 1), "", 0, neverLoad); !ov {
		t.Error("没有候选时该用设备封面")
	}
	if ov, _ := deviceCoverDecision(synthCover(120, 1), "   ", 0, neverLoad); !ov {
		t.Error("候选是纯空白时该用设备封面")
	}

	// ③ 候选尺寸认不出来 → 保守顶掉(证不出它更好),不取图
	if ov, why := deviceCoverDecision(synthCover(120, 1), "https://example.com/c.jpg", 0, neverLoad); !ov {
		t.Errorf("候选尺寸认不出时该保留设备封面, why=%s", why)
	}

	// ④ 候选不比设备图大 → 顶掉,不取图
	if ov, _ := deviceCoverDecision(synthCover(120, 1), neteaseBig, 120, neverLoad); !ov {
		t.Error("候选跟设备图一样大时该保留设备封面")
	}
	if ov, _ := deviceCoverDecision(synthCover(120, 1), neteaseBig, 64, neverLoad); !ov {
		t.Error("候选比设备图小时该保留设备封面")
	}

	// ⑤ 候选更大 + **同一张图** → 让位给高清候选。这就是《24K Magic》那一档。
	ov, why := deviceCoverDecision(synthCover(120, 1), neteaseBig, 800, load(synthCover(800, 1)))
	if ov {
		t.Errorf("同一张图时该改用更清晰的候选, why=%s", why)
	}

	// ⑥ 候选更大但**不是同一张** → 保留设备封面。⚠️ Immortal 那一档:设备那张小但对,
	//    候选那张大但挂错了。这条断言就是那个 bug 的回归测试。
	ov, why = deviceCoverDecision(synthCover(120, 1), neteaseBig, 800, load(synthCover(800, 4)))
	if !ov {
		t.Errorf("候选是另一张图时必须保留设备封面(否则 Immortal 那个 bug 复发), why=%s", why)
	}

	// ⑦ 候选取不到/解不出来 → 顶掉(退回改动前的行为)
	if ov, _ := deviceCoverDecision(synthCover(120, 1), neteaseBig, 800, load(nil)); !ov {
		t.Error("候选取不到时该保留设备封面")
	}

	// ⑧ 设备图本身解不出来 → 不顶掉(别拿一张解不出来的图换掉好候选)
	if ov, _ := deviceCoverDecision(nil, neteaseBig, 800, neverLoad); ov {
		t.Error("设备图解不出来时不该顶掉候选")
	}
}

func TestMinEdge(t *testing.T) {
	if got := minEdge(image.NewRGBA(image.Rect(0, 0, 120, 300))); got != 120 {
		t.Errorf("minEdge 该取短边, got %d", got)
	}
	if got := minEdge(image.NewRGBA(image.Rect(0, 0, 300, 120))); got != 120 {
		t.Errorf("minEdge 该取短边(反向), got %d", got)
	}
	if got := minEdge(nil); got != 0 {
		t.Errorf("minEdge(nil) 该是 0, got %d", got)
	}
}

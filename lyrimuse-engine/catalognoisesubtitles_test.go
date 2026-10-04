package main

import (
	"encoding/json"
	"os"
	"reflect"
	"regexp"
	"sort"
	"testing"
)

// 目录学噪音副题:这边按它决定收听记到 Last.fm 的哪一条,App(PlayCountVariants.isCatalogNoiseSubtitle)按它算「第 N 次听」时
// 把哪几种写法合在一起,两边漂开数就对不上。共用样例两边一起跑。
func TestCatalogNoiseSubtitlesMatchSharedSamples(t *testing.T) {
	raw, err := os.ReadFile("../shared/testdata/catalog-noise-subtitles.json")
	if err != nil {
		t.Fatal(err)
	}
	var s struct {
		Noise    []string `json:"noise"`
		NotNoise []string `json:"not_noise"`
	}
	if err := json.Unmarshal(raw, &s); err != nil || len(s.Noise) < 10 || len(s.NotNoise) < 10 {
		t.Fatalf("读不出共用样例: %v", err)
	}
	for _, sub := range s.Noise {
		if !isCatalogNoiseSubtitle(sub) {
			t.Errorf("%q 是噪音,该剥掉", sub)
		}
	}
	for _, sub := range s.NotNoise {
		if isCatalogNoiseSubtitle(sub) {
			t.Errorf("%q 不是噪音,该留着", sub)
		}
	}
}

// `(with …)` 后面不是人的头词:两边是同一张表(App 侧 PlayCountVariants.nonCreditHeadWords),逐词对账。
func TestCatalogNonCreditHeadWordsMatchTheApp(t *testing.T) {
	src, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Local/HanScript.swift")
	if err != nil {
		t.Fatal(err)
	}
	block := regexp.MustCompile(`(?s)static let nonCreditHeadWords: Set<String> = \[(.*?)\]`).FindSubmatch(src)
	if block == nil {
		t.Fatal("HanScript.swift 里找不到 nonCreditHeadWords(改名了?同步更新这个测试)")
	}
	var swift, goSide []string
	for _, m := range regexp.MustCompile(`"([^"]+)"`).FindAllSubmatch(block[1], -1) {
		swift = append(swift, string(m[1]))
	}
	for w := range catalogNonCreditHeadWords {
		goSide = append(goSide, w)
	}
	sort.Strings(swift)
	sort.Strings(goSide)
	if len(swift) == 0 || !reflect.DeepEqual(swift, goSide) {
		t.Fatalf("两边的头词表不一致:\n Swift %v\n Go    %v", swift, goSide)
	}
}

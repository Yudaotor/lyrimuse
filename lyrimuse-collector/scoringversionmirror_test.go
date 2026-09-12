package main

import (
	"os"
	"regexp"
	"strconv"
	"testing"
)

// 打分算法版本号在两边各存一份(Go 的 lyricsScoringVersion / App 的 currentLyricsScoringVersion),
// 靠"改一处记得改另一处"维持 —— 而实测它已经漂了很久:2026-09-12 发现 Go 早就到 17、Swift 还停在
// 6。后果**完全静默**:App 那句 `version < currentLyricsScoringVersion` 是用来给旧存档打「旧打分
// 算法」标记的,镜像值落后时库里所有存档都 >= 它,于是这个标记从某一版起就再没出现过,既不编译
// 报错也不会有人察觉。
//
// 这条守卫跟 TestLyricQueryReasonsHaveChineseLabels 同一个路子:凡是"两边各存一份、只能靠人记得"
// 的东西,就用一条读对方源码的测试钉死。
func TestScoringVersionMirroredInApp(t *testing.T) {
	const sheet = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift"
	data, err := os.ReadFile(sheet)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", sheet, err)
	}
	m := regexp.MustCompile(`currentLyricsScoringVersion\s*=\s*(\d+)`).FindStringSubmatch(string(data))
	if m == nil {
		t.Fatalf("%s 里找不到 currentLyricsScoringVersion —— 改名了就同步改这个测试", sheet)
	}
	mirrored, err := strconv.Atoi(m[1])
	if err != nil {
		t.Fatalf("镜像值不是整数: %q", m[1])
	}
	if mirrored != lyricsScoringVersion {
		t.Errorf("打分版本两边不一致: Go lyricsScoringVersion=%d, App currentLyricsScoringVersion=%d —— "+
			"改打分公式时两处要一起改,否则 App 的「旧打分算法」标记会静默失效",
			lyricsScoringVersion, mirrored)
	}
}

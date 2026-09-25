package main

import (
	"strings"
	"testing"
)

// 脚本那半依赖真机上 Music.app 此刻的状态,单测里跑不了 —— 三道守卫只能靠扫源码钉住。
// 少任意一道的后果都写在 appleMusicUpcomingScript 的头注里(拉起没开的 App / 拿停着时
// 的陈旧曲目 / 随机播放时按资料库顺序瞎猜)。
func TestAppleMusicUpcomingScriptKeepsItsGuards(t *testing.T) {
	guards := []struct{ needle, why string }{
		{`if application "Music" is not running then`, "没有 running 守卫会把没开的 Music.app 静默拉起来"},
		{"if player state is stopped then return", "停着时 current track 还留着上一次的值"},
		{"if shuffle enabled then return", "随机播放时 index+1 指的不是接下来会播的那首"},
		{"on error", "播云端歌单时 current playlist 直接报 -1728,得兜住"},
	}
	for _, g := range guards {
		if !strings.Contains(appleMusicUpcomingScript, g.needle) {
			t.Errorf("脚本里少了守卫 %q —— %s", g.needle, g.why)
		}
	}
}

func TestParseAppleMusicUpcoming(t *testing.T) {
	// 第一行是脚本报回来的"它认为正在播的那首",其余每行是 名\t歌手\t专辑\t时长(秒)。
	out := "Earth Song\tMichael Jackson\n" +
		"You Are Not Alone\tMichael Jackson\tHIStory Continues\t344.825988769531\n" +
		"The Lost Children\tMichael Jackson\tInvincible\t240.533004760742\n"
	got, ok := parseAppleMusicUpcoming(out, "Michael Jackson", "Earth Song", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该解出 2 首,得到 ok=%v got=%+v", ok, got)
	}
	if got[0].title != "You Are Not Alone" || got[0].artist != "Michael Jackson" {
		t.Errorf("第 1 首解错: %+v", got[0])
	}
	// 跨专辑是正常的 —— 从本地歌单播时队列里每首的专辑各不相同。
	if got[0].album != "HIStory Continues" || got[1].album != "Invincible" {
		t.Errorf("专辑名解错: %q / %q", got[0].album, got[1].album)
	}
	if got[0].duration != 344.825988769531 {
		t.Errorf("时长 %v —— Music.app 的 duration 本来就是秒,别再除一遍", got[0].duration)
	}
}

func TestParseAppleMusicUpcomingRejectsMismatchedHead(t *testing.T) {
	// 脚本看到的"正在播"跟 poller 手上的对不上 —— 说明两边看的不是同一个播放器,
	// 照着它预取等于拿一批无关的歌去占解析带宽。
	out := "别的歌\t别的歌手\nA\t甲\t专辑\t100\n"
	if got, ok := parseAppleMusicUpcoming(out, "Michael Jackson", "Earth Song", 5); ok {
		t.Errorf("首行对不上时该返回 false,却返回了 %+v", got)
	}
}

func TestParseAppleMusicUpcomingEmptyMeansGuardTripped(t *testing.T) {
	// 三道守卫任意一道拦下时脚本返回空串。这不是错误,是"这一刻不该用这条路"。
	for _, out := range []string{"", "\n", "   \n"} {
		if _, ok := parseAppleMusicUpcoming(out, "甲", "乙", 5); ok {
			t.Errorf("空输出(守卫拦下)该返回 false,输入 %q", out)
		}
	}
}

func TestParseAppleMusicUpcomingHonorsLimit(t *testing.T) {
	var b strings.Builder
	b.WriteString("当前\t甲\n")
	for _, n := range []string{"一", "二", "三", "四", "五", "六", "七"} {
		b.WriteString(n + "\t歌手\t专辑\t100\n")
	}
	got, ok := parseAppleMusicUpcoming(b.String(), "甲", "当前", 3)
	if !ok || len(got) != 3 {
		t.Fatalf("该截到 3 首,得到 ok=%v len=%d", ok, len(got))
	}
}

// AppleScript 实数转文本跟随系统地区:德 / 法 / 俄等地区下小数点是逗号,≥10000 还会变科学计数。
// 这些值都是 `osascript 脚本 -AppleLocale de_DE` 实测输出的形状。
func TestParseAppleScriptRealAcceptsLocaleDecimalComma(t *testing.T) {
	cases := []struct {
		in   string
		want float64
	}{
		{"243.826", 243.826},
		{"243,826", 243.826},
		{"3,25\n", 3.25},
		{"25,0", 25},
		{"1,23455E+4", 12345.5},
		{"1.23455E+4", 12345.5},
		{"208", 208},
	}
	for _, c := range cases {
		got, err := parseAppleScriptReal(c.in)
		if err != nil || got != c.want {
			t.Errorf("parseAppleScriptReal(%q) = %v, %v;要 %v", c.in, got, err, c.want)
		}
	}
	for _, bad := range []string{"", "x", "missing value"} {
		if _, err := parseAppleScriptReal(bad); err == nil {
			t.Errorf("parseAppleScriptReal(%q) 该报错", bad)
		}
	}
}

func TestParseAppleMusicUpcomingLocaleDecimalComma(t *testing.T) {
	out := "Earth Song\tMichael Jackson\n" +
		"You Are Not Alone\tMichael Jackson\tHIStory Continues\t344,825988769531\n"
	got, ok := parseAppleMusicUpcoming(out, "Michael Jackson", "Earth Song", 5)
	if !ok || len(got) != 1 {
		t.Fatalf("该解出 1 首,得到 ok=%v got=%+v", ok, got)
	}
	if got[0].duration != 344.825988769531 {
		t.Errorf("逗号小数点的时长解成了 %v —— 逗号地区下会静默变 0,预取选源少了时长这一票", got[0].duration)
	}
}

func TestParseMusicAppAlbumTracks(t *testing.T) {
	out := "Bad\tMichael Jackson\t247,16\n" +
		"The Way You Make Me Feel\tMichael Jackson\t298.426\r\n" +
		"\n" +
		"坏行\n" +
		"Speed Demon\tMichael Jackson\tmissing value\n"
	got := parseMusicAppAlbumTracks(out)
	if len(got) != 3 {
		t.Fatalf("该解出 3 首(空行和缺列的行跳过),得到 %+v", got)
	}
	if got[0].duration != 247.16 || got[1].duration != 298.426 {
		t.Errorf("时长解错: %v / %v", got[0].duration, got[1].duration)
	}
	if got[1].title != "The Way You Make Me Feel" {
		t.Errorf("行尾 \\r 没剥掉: %q", got[1].title)
	}
	if got[2].duration != 0 {
		t.Errorf("解不出的时长该按未知(0)处理,得到 %v", got[2].duration)
	}
}

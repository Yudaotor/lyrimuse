package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 这组测试全部用**合成**的 SONGS 表,不读本机真实的 QQ 音乐库:CI 上没有 QQ 音乐,而且
// 一份会随用户听歌变化的数据当不了断言基准。

func sqlQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// writeTestQQDB 建一张只含本代码用得上的那几列的 SONGS(真实表有 83 列,其余与我们无关)。
func writeTestQQDB(t *testing.T, rows []qqLocalRow) string {
	t.Helper()
	// 路径里**故意**带空格,照搬真实路径里 "Application Support" 那一段 —— file: URI 忘了
	// 转义就会在这里炸(sqlite3 收到被截断的文件名),而不是等到真机上才发现。
	dir := filepath.Join(t.TempDir(), "Application Support")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录失败: %v", err)
	}
	path := filepath.Join(dir, "qqmusic.sqlite")
	var sb strings.Builder
	sb.WriteString("CREATE TABLE SONGS (id BIGINT, type INTEGER, name TEXT, singer TEXT," +
		" album TEXT, K_SONG_RESERVE1 TEXT, K_SONG_RESERVE12 INTEGER);\n")
	for i, r := range rows {
		sb.WriteString(fmt.Sprintf("INSERT INTO SONGS VALUES (%d,13,%s,%s,%s,%s,%d);\n",
			i+1, sqlQuote(r.Name), sqlQuote(r.Singer), sqlQuote(r.Album), sqlQuote(r.Mid), r.MS))
	}
	cmd := exec.Command("/usr/bin/sqlite3", path)
	cmd.Stdin = strings.NewReader(sb.String())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("建测试库失败(没有 /usr/bin/sqlite3?): %v %s", err, out)
	}
	return path
}

func resetQQLocalIndex(t *testing.T, dbPath string) {
	t.Helper()
	clear := func() {
		qqLocalMu.Lock()
		qqLocalIndex, qqLocalReady, qqLocalScanned = nil, false, time.Time{}
		qqLocalDBMod, qqLocalDBSize = time.Time{}, 0
		qqLocalMu.Unlock()
	}
	clear()
	old := qqLocalDBOverride
	qqLocalDBOverride = dbPath
	t.Cleanup(func() {
		qqLocalDBOverride = old
		clear()
	})
}

var qqLocalTestRows = []qqLocalRow{
	{Mid: "003FdJZH1wljMU", Name: "西西里", Singer: "周杰伦", Album: "太阳之子", MS: 229000},
	{Mid: "0039MnYb0qxYhV", Name: "晴天", Singer: "周杰伦", Album: "叶惠美", MS: 269000},
	{Mid: "001lsqXt3tWycC", Name: "Right Girl", Singer: "方大同", Album: "未来", MS: 231000},
}

func TestQQLocalMatchHit(t *testing.T) {
	resetQQLocalIndex(t, writeTestQQDB(t, qqLocalTestRows))
	m, ok := qqLocalMatch(context.Background(), "周杰伦", "西西里", "太阳之子", 229)
	if !ok {
		t.Fatal("应当命中本地曲库")
	}
	// url 必须是 qqSongURL 那个形状——下游 enrich.go 是靠 qqMidFromURL 把 mid 解回去的,
	// 形状不对会静默退化成"拿不到 mid",比不命中还难查。
	if got := qqMidFromURL(m.url); got != "003FdJZH1wljMU" {
		t.Fatalf("url 里解不回 mid: url=%q got=%q", m.url, got)
	}
	if m.title != "西西里" || m.artist != "周杰伦" || m.album != "太阳之子" {
		t.Fatalf("元数据没透传: %+v", m)
	}
	if m.interval != 229 {
		t.Fatalf("时长应为秒(229),得到 %v", m.interval)
	}
	if m.unreliable {
		t.Fatal("本地命中不该标 unreliable")
	}
}

func TestQQLocalMatchTraditionalAndCase(t *testing.T) {
	resetQQLocalIndex(t, writeTestQQDB(t, qqLocalTestRows))
	// 播放器报繁体(Apple Music 的中文曲库大量如此),库里是简体;归一化走 normLoose,
	// 跟这个仓库其它跨源匹配同一把尺子。
	if _, ok := qqLocalMatch(context.Background(), "周杰倫", "晴天", "", 269); !ok {
		t.Fatal("繁体歌手名应当命中")
	}
	if _, ok := qqLocalMatch(context.Background(), "方大同", "RIGHT GIRL", "", 231); !ok {
		t.Fatal("大小写不同应当命中")
	}
}

func TestQQLocalMatchRejectsDurationMismatch(t *testing.T) {
	resetQQLocalIndex(t, writeTestQQDB(t, qqLocalTestRows))
	// 库里 229s,播放器在放 300s 的另一版(差 23.7% > 12%)。宁可不命中、老实走网络搜索,
	// 也不能把另一版的 mid 交出去——逐字歌词时间轴会整首错位。
	if m, ok := qqLocalMatch(context.Background(), "周杰伦", "西西里", "", 300); ok {
		t.Fatalf("时长差 >12%% 不该命中,却给了 %+v", m)
	}
	// 播放器没报时长(0)时 sourceDurationFits 不下结论 → 照常命中。
	if _, ok := qqLocalMatch(context.Background(), "周杰伦", "西西里", "", 0); !ok {
		t.Fatal("时长未知时应当命中")
	}
}

func TestQQLocalMatchPicksAmongSameNameVersions(t *testing.T) {
	rows := []qqLocalRow{
		{Mid: "midLive", Name: "晴天", Singer: "周杰伦", Album: "演唱会", MS: 281000},
		{Mid: "midStudio", Name: "晴天", Singer: "周杰伦", Album: "叶惠美", MS: 269000},
	}
	resetQQLocalIndex(t, writeTestQQDB(t, rows))
	// 两条都过 12% 闸(281 vs 269 差 4.3%),按时长差挑到录音室版。
	m, ok := qqLocalMatch(context.Background(), "周杰伦", "晴天", "", 269)
	if !ok || qqMidFromURL(m.url) != "midStudio" {
		t.Fatalf("应按时长挑中 midStudio,得到 ok=%v url=%q", ok, m.url)
	}
	// 有专辑名时专辑优先级更高——即便时长差略大也该选专辑对得上的那条。
	m, ok = qqLocalMatch(context.Background(), "周杰伦", "晴天", "演唱会", 269)
	if !ok || qqMidFromURL(m.url) != "midLive" {
		t.Fatalf("应按专辑挑中 midLive,得到 ok=%v url=%q", ok, m.url)
	}
}

func TestQQLocalMatchMissingDB(t *testing.T) {
	resetQQLocalIndex(t, filepath.Join(t.TempDir(), "没有这个库.sqlite"))
	if _, ok := qqLocalMatch(context.Background(), "周杰伦", "晴天", "", 269); ok {
		t.Fatal("库不存在时不该命中")
	}
}

func TestQQLocalMatchNeedsArtist(t *testing.T) {
	resetQQLocalIndex(t, writeTestQQDB(t, qqLocalTestRows))
	// 歌手名缺失时不做"只按歌名"的兜底:这条路径的全部价值就是不靠猜。
	if _, ok := qqLocalMatch(context.Background(), "", "西西里", "", 229); ok {
		t.Fatal("歌手名为空时不该命中")
	}
}

func TestQueryQQLocalSongsEmptyResultIsNotAnError(t *testing.T) {
	path := writeTestQQDB(t, nil) // 建了表但一行没有
	rows, err := queryQQLocalSongs(context.Background(), path)
	// ⚠️ sqlite3 -json 对零行输出的是**空串**不是 "[]";当成 JSON 错误的话,"库里没这首歌"
	// 会被错记成"读库失败",进而让 refresh 保留陈旧索引。
	if err != nil {
		t.Fatalf("零行结果不该报错: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("零行结果应当返回空切片,得到 %d 行", len(rows))
	}
}

func TestQueryQQLocalSongsReadsSpacedPath(t *testing.T) {
	path := writeTestQQDB(t, qqLocalTestRows)
	if !strings.Contains(path, " ") {
		t.Fatal("测试前提失效:路径里应当带空格")
	}
	rows, err := queryQQLocalSongs(context.Background(), path)
	if err != nil {
		t.Fatalf("带空格的路径读失败(URI 没转义?): %v", err)
	}
	if len(rows) != len(qqLocalTestRows) {
		t.Fatalf("应读回 %d 行,得到 %d", len(qqLocalTestRows), len(rows))
	}
	if rows[0].MS != 229000 {
		t.Fatalf("毫秒时长没读对: %+v", rows[0])
	}
}

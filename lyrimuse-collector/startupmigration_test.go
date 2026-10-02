package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// 水位闸的行为契约。它决定 migrateLyricTimelines 这类存量迁移跑不跑,判错的代价是
// **静默少跑一道迁移** —— 不报错、不红、只有存量数据一直停在旧形态,所以每一条都钉住。
func TestStartupMigrationState(t *testing.T) {
	saved, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() { migrationState, migrationStatePath = saved, savedPath })

	path := filepath.Join(t.TempDir(), "migrations.json")
	loadMigrationState(path)

	// 没跑过 → 该跑。
	if migrationDone("x", 1) {
		t.Error("水位文件不存在时该判为没跑过")
	}
	markMigrationDone("x", 1)
	if !migrationDone("x", 1) {
		t.Error("标记完该判为跑过")
	}

	// 版本号是"改了算法就重扫存量"的唯一开关:水位停在 1 时,要求 2 必须判为没跑过。
	if migrationDone("x", 2) {
		t.Error("水位低于要求的版本时该判为没跑过(改算法后存量要重扫)")
	}

	// 落了盘,新进程读得回来。
	migrationState = nil
	loadMigrationState(path)
	if !migrationDone("x", 1) {
		t.Error("水位该落盘并在重新载入后仍然成立")
	}

	// 外来数据进来 → 全部作废。
	invalidateMigrationState("test")
	if migrationDone("x", 1) {
		t.Error("作废之后该判为没跑过")
	}
	migrationState = nil
	loadMigrationState(path)
	if migrationDone("x", 1) {
		t.Error("作废要落盘,不能只改内存")
	}
}

// 路径没设 = 各 CLI 子命令的形态:水位必须整个失效,行为与加这层之前逐字节一致。
// 判反了的后果是 CLI 里那些迁移被静默跳过。
func TestStartupMigrationStateDisabledWithoutPath(t *testing.T) {
	saved, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() { migrationState, migrationStatePath = saved, savedPath })

	migrationStatePath = ""
	migrationState = map[string]int{"x": 9}
	if migrationDone("x", 1) {
		t.Error("没有水位文件路径时,水位必须整个失效(CLI 子命令要跟加这层之前一样全量跑)")
	}
	// 写也不能写出去 —— 没有路径可写,更不能 panic。
	markMigrationDone("x", 1)
	invalidateMigrationState("test")
}

// 水位文件坏了(手工编辑坏、写一半崩)必须退化成"全部重跑",不能退化成"全部跳过" ——
// 这一层最坏的失效方式只允许是多跑一遍。
func TestStartupMigrationStateCorruptFileRerunsEverything(t *testing.T) {
	saved, savedPath := migrationState, migrationStatePath
	t.Cleanup(func() { migrationState, migrationStatePath = saved, savedPath })

	path := filepath.Join(t.TempDir(), "migrations.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	loadMigrationState(path)
	if migrationDone(migrationLyricTimelines, migrationLyricTimelinesVersion) {
		t.Error("水位文件解不出来时该判为一道都没跑过")
	}
}

// lyrics/ 文件夹只改写了几条:跑过的迁移这一轮只补扫那几条,补完各自把水位写回;没跑过的、升了版本号的照常全量。
// 补扫写回之前,磁盘上的水位是作废的 —— 中途被杀,下次启动全量跑,不会少跑。
func TestStartupMigrationRecheckOnlyRewrittenEntries(t *testing.T) {
	withTempMigrationState(t)
	path := migrationStatePath
	markMigrationDone("x", 1)
	markMigrationDone("y", 3)

	recheckMigrationsFor([]string{"a|t|b"}, "test")
	if s := migrationScopeOf("x", 1); s.all || len(s.keys) != 1 || s.keys[0] != "a|t|b" {
		t.Fatalf("跑过的迁移该只补扫改写过的那一条: %+v", s)
	}
	if s := migrationScopeOf("x", 2); !s.all {
		t.Errorf("升了版本号的照常全量: %+v", s)
	}
	if s := migrationScopeOf("z", 1); !s.all {
		t.Errorf("没跑过的照常全量: %+v", s)
	}
	if disk := readMigrationStateForTest(t, path); len(disk) != 0 {
		t.Errorf("补扫一开始磁盘上的水位就要作废(中途被杀,下次全量跑): %v", disk)
	}

	markMigrationDone("x", 1)
	if s := migrationScopeOf("x", 1); !s.skip() {
		t.Errorf("补扫完写回水位,这一道之后整道跳过: %+v", s)
	}
	if disk := readMigrationStateForTest(t, path); disk["x"] != 1 || disk["y"] != 0 {
		t.Errorf("补扫完的那道写回磁盘,还没补扫的那道不能提前写回: %v", disk)
	}

	// 补扫之后又整体作废(比如从快照恢复):全量跑,不能还按补扫的范围。
	invalidateMigrationState("test")
	if s := migrationScopeOf("y", 3); !s.all {
		t.Errorf("整体作废之后该全量跑: %+v", s)
	}
}

// 补扫到一半进程被杀:新进程读到的是作废的水位,全量跑。
func TestStartupMigrationRecheckInterruptedRerunsInFull(t *testing.T) {
	withTempMigrationState(t)
	path := migrationStatePath
	markMigrationDone("x", 1)
	recheckMigrationsFor([]string{"a|t|b"}, "test")
	loadMigrationState(path) // 新进程
	if s := migrationScopeOf("x", 1); !s.all {
		t.Errorf("补扫没写回水位就被杀,下次启动要全量跑: %+v", s)
	}
}

// 补扫期间内存里的水位是空的:这时整体作废也得生效,不能被"没东西可作废"的早退漏掉。一道都没跑过时补扫是
// 空操作(这一轮本来就全量跑);没有水位文件路径(CLI 子命令)同理。
func TestStartupMigrationRecheckEdges(t *testing.T) {
	withTempMigrationState(t)
	recheckMigrationsFor([]string{"a|t|b"}, "test")
	if s := migrationScopeOf("x", 1); !s.all {
		t.Errorf("一道都没跑过时补扫是空操作,照常全量: %+v", s)
	}

	markMigrationDone("x", 1)
	recheckMigrationsFor([]string{"a|t|b"}, "test")
	invalidateMigrationState("test")
	if s := migrationScopeOf("x", 1); !s.all {
		t.Errorf("补扫期间整体作废,要改成全量: %+v", s)
	}

	markMigrationDone("x", 1)
	migrationStatePath = ""
	recheckMigrationsFor([]string{"a|t|b"}, "test")
	if s := migrationScopeOf("x", 1); !s.all {
		t.Errorf("没有水位文件路径时照常全量: %+v", s)
	}
}

// 真迁移走补扫:只动改写过的那一条,没改写过的原样(实体解码不幂等,多扫一遍就多解一层);缓存里已经没有的
// key 不凭空造条目;补完水位写回,下一轮整道跳过。
func TestMigrateLyricEntitiesRechecksOnlyRewrittenEntries(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	enrichMu.Lock()
	enrichPath = ""
	enrichCache["a|imported|b"] = enrichEntry{Lyrics: "[00:01.00]they&apos;re"}
	enrichCache["a|other|b"] = enrichEntry{Lyrics: "[00:01.00]we&amp;apos;re"}
	enrichMu.Unlock()
	markMigrationDone(migrationLyricEntities, migrationLyricEntitiesVersion)

	recheckMigrationsFor([]string{"a|imported|b", "a|gone|b"}, "test")
	migrateLyricEntities()
	enrichMu.Lock()
	imported, other := enrichCache["a|imported|b"].Lyrics, enrichCache["a|other|b"].Lyrics
	_, gone := enrichCache["a|gone|b"]
	enrichMu.Unlock()
	if imported != "[00:01.00]they're" {
		t.Errorf("改写过的那条要补扫: %q", imported)
	}
	if other != "[00:01.00]we&amp;apos;re" {
		t.Errorf("没改写过的不补扫: %q", other)
	}
	if gone {
		t.Error("缓存里没有的 key 不该被补扫造出来")
	}
	if s := migrationScopeOf(migrationLyricEntities, migrationLyricEntitiesVersion); !s.skip() {
		t.Errorf("补扫完要写回水位: %+v", s)
	}
}

// 带水位的迁移都要按 migrationScopeOf 定的范围扫:直接问 migrationDone 的那一道,lyrics/ 文件夹改一个文件
// 它就又全库重扫(不会错,只是慢回去)。main.go 的导入那一步要走补扫,不是整体作废。
func TestWatermarkedMigrationsHonorRecheckScope(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	direct := regexp.MustCompile(`\bmigrationDone\(`)
	gated := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") || f == "startupmigration.go" {
			continue
		}
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(data)
		if direct.MatchString(src) {
			t.Errorf("%s 直接问 migrationDone,改用 migrationScopeOf", f)
		}
		marks := strings.Count(src, "markMigrationDone(")
		scopes := strings.Count(src, "migrationScopeOf(")
		ranges := strings.Count(src, "range scope.entries()")
		if marks != scopes || scopes != ranges {
			t.Errorf("%s: markMigrationDone %d 处、migrationScopeOf %d 处、range scope.entries() %d 处,要一一对应", f, marks, scopes, ranges)
		}
		gated += marks
	}
	if gated == 0 {
		t.Fatal("一道带水位的迁移都没找到,这条检查本身失效了")
	}
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "recheckMigrationsFor(keys, ") {
		t.Error("main.go 导入 lyrics/ 那一步要让迁移补扫改写过的条目(recheckMigrationsFor),不是整体作废水位")
	}
}

func readMigrationStateForTest(t *testing.T, path string) map[string]int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]int
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	return got
}

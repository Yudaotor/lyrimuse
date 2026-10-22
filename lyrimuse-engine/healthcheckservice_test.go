package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseLaunchdPrint(t *testing.T) {
	running := "gui/501/com.lyrimuse.collector = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n\tjob state = exited\n\tendpoints = {\n\t\tstate = active\n\t}\n}\n"
	job := parseLaunchdPrint(0, running)
	if !job.registered || !job.stateKnown || !job.running || job.pid != 4242 {
		t.Fatalf("running job parsed as %+v", job)
	}

	stopped := "x = {\n\tstate = not running\n\tlast exit code = 78: EX_CONFIG\n\t\tstate = active\n}\n"
	job = parseLaunchdPrint(0, stopped)
	if !job.registered || !job.stateKnown || job.running || job.lastExit != "78: EX_CONFIG" {
		t.Fatalf("stopped job parsed as %+v (nested state = active must not count)", job)
	}

	if job := parseLaunchdPrint(113, "Could not find service"); job.registered {
		t.Fatalf("exit 113 must read as not registered, got %+v", job)
	}
	if job := parseLaunchdPrint(0, "x = {\n\t\tstate = active\n}\n"); !job.registered || job.stateKnown {
		t.Fatalf("only a nested state field must read as unknown, got %+v", job)
	}
}

func TestEngineServiceHealthItem(t *testing.T) {
	cases := []struct {
		name   string
		job    launchdJobState
		status healthStatus
		detail string
	}{
		{"not registered", launchdJobState{}, healthFail, "没有注册"},
		{"running", launchdJobState{registered: true, stateKnown: true, running: true, pid: 7}, healthOK, "pid 7"},
		{"exit 78", launchdJobState{registered: true, stateKnown: true, lastExit: "78: EX_CONFIG"}, healthFail, "日志文件写不进"},
		{"unknown", launchdJobState{registered: true}, healthWarn, "认不出"},
	}
	for _, c := range cases {
		item := engineServiceHealthItem(c.job)
		if item.Status != c.status || !strings.Contains(item.Detail, c.detail) {
			t.Errorf("%s: got %s %q, want %s containing %q", c.name, item.Status, item.Detail, c.status, c.detail)
		}
	}
}

func TestFolderAccessHealthItem(t *testing.T) {
	uid := os.Getuid()
	if uid == 0 {
		t.Skip("root can write anywhere; the not-writable case cannot be built")
	}
	dir := t.TempDir()
	okDir := filepath.Join(dir, "ok")
	readOnly := filepath.Join(dir, "readonly")
	plist := filepath.Join(dir, engineLaunchdLabel+".plist")
	for _, d := range []string{okDir, readOnly} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(plist, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(plist, 0o666); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(readOnly, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(readOnly, 0o755) })

	all := folderAccessHealthItem([]homeFolderTarget{
		{path: okDir},
		{path: filepath.Join(dir, "missing")},
		{path: readOnly, ownsTree: true},
		{path: "/"},
		{path: plist, launchdPlist: true},
	}, uid, "someone")
	if all.Status != healthFail {
		t.Fatalf("problems must fail, got %s %q", all.Status, all.Detail)
	}
	for _, want := range []string{
		readOnly + " 没有写入权限",
		"/ 属于 ",
		"其他用户也可写(666)",
		"sudo chown -R 'someone':staff '" + readOnly + "' && chmod -R u+rwX '" + readOnly + "'",
		"chmod 644 '" + plist + "'",
		// 共用目录只改它本身,不递归改里面别的程序的文件。
		"sudo chown 'someone':staff '/' && chmod u+rwX '/'",
	} {
		if !strings.Contains(all.Detail, want) {
			t.Errorf("detail %q misses %q", all.Detail, want)
		}
	}
	if strings.Contains(all.Detail, "chown -R 'someone':staff '/'") {
		t.Errorf("a shared folder must not get a recursive chown: %q", all.Detail)
	}
	if strings.Contains(all.Detail, okDir+" ") || strings.Contains(all.Detail, "missing") {
		t.Errorf("a writable or missing location must not be reported: %q", all.Detail)
	}

	// 同一份 plist 不当 launchd plist 查时,666 不算问题。
	if item := folderAccessHealthItem([]homeFolderTarget{{path: okDir}, {path: plist}}, uid, "someone"); item.Status != healthOK {
		t.Errorf("writable locations owned by the user must pass, got %s %q", item.Status, item.Detail)
	}
}

// 只有 Lyrimuse 自己的配置目录整棵改(ownsTree);共用目录(配置目录的上一层、LaunchAgents、日志目录)和单个文件不标,
// 跟 App 的 HomeFolderAccess.targets 同一份口径。
func TestHomeFolderTargetsMarkOwnedTree(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LYRIMUSE_CONFIG_DIR", "")
	t.Setenv("LYRIMUSE_LOG_FILE", "")
	owns := map[string]bool{}
	for _, target := range homeFolderTargets() {
		owns[target.path] = target.ownsTree
	}
	want := map[string]bool{
		filepath.Join(home, ".config"):                                           false,
		filepath.Join(home, ".config", clientName):                               true,
		filepath.Join(home, "Library/LaunchAgents"):                              false,
		filepath.Join(home, "Library/Logs"):                                      false,
		filepath.Join(home, "Library/Logs", clientName+".log"):                   false,
		filepath.Join(home, "Library/LaunchAgents", engineLaunchdLabel+".plist"): false,
	}
	if len(owns) != len(want) {
		t.Fatalf("targets = %v, want %v", owns, want)
	}
	for path, isOwned := range want {
		if got, ok := owns[path]; !ok || got != isOwned {
			t.Errorf("%s: ownsTree=%v (present %v), want %v", path, got, ok, isOwned)
		}
	}
}

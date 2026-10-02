package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 卸载脚本按确切文件名删引擎日志的轮转归档:份数和名字要跟 logRotateKeepArchives / logArchiveName 对得上,
// 改了保留份数、忘了改脚本,--purge 就会留下归档。
func TestUninstallScriptListsEveryLogArchive(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "lyrimuse", "scripts", "uninstall.sh"))
	if err != nil {
		t.Fatalf("read uninstall.sh: %v", err)
	}
	for i := 0; i < logRotateKeepArchives; i++ {
		if name := `"` + logArchiveName("$LOG_FILE", i) + `"`; !strings.Contains(string(src), name) {
			t.Errorf("uninstall.sh 没列归档 %s", name)
		}
	}
}

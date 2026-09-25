package main

import (
	"os"
	"path/filepath"
	"testing"
)

// fakeApp 在临时目录造一个最小的 .app:Info.plist 里写 OSAScriptingDefinition,Resources 下放 sdef。
func fakeApp(t *testing.T, sdefKey, sdefFile, sdefBody string) string {
	t.Helper()
	app := filepath.Join(t.TempDir(), "Fake.app")
	res := filepath.Join(app, "Contents", "Resources")
	if err := os.MkdirAll(res, 0o755); err != nil {
		t.Fatal(err)
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fake</string>`
	if sdefKey != "" {
		plist += `<key>OSAScriptingDefinition</key><string>` + sdefKey + `</string>`
	}
	plist += `</dict></plist>`
	if err := os.WriteFile(filepath.Join(app, "Contents", "Info.plist"), []byte(plist), 0o644); err != nil {
		t.Fatal(err)
	}
	if sdefFile != "" {
		if err := os.WriteFile(filepath.Join(res, sdefFile), []byte(sdefBody), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return app
}

// 认四字码不认命令名:Chromium 系是 CrSuExJa,Safari 是 sfridojs;都没有、没有 sdef 键都判不了。
func TestScriptFamilyForApp(t *testing.T) {
	cases := []struct {
		name, key, file, body, want string
	}{
		{"chromium", "Brave.sdef", "Brave.sdef", `<command name="execute" code="CrSuExJa">`, "chromium"},
		{"safari", "Orion.sdef", "Orion.sdef", `<command name="do JavaScript" code="sfridojs">`, "safari"},
		{"没有 JavaScript 命令", "Music.sdef", "Music.sdef", `<command name="play" code="hookPlay">`, ""},
		{"没有 sdef 键", "", "", "", ""},
		{"sdef 文件不存在", "Missing.sdef", "", "", ""},
		// 键里带 ../ 也只取文件名:读的是 Resources 下同名文件,不会读到 bundle 外面去。
		{"越界文件名只取文件名", "../../Evil.sdef", "Evil.sdef", `code="CrSuExJa"`, "chromium"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := scriptFamilyForApp(fakeApp(t, c.key, c.file, c.body)); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// 只对信任列表里的浏览器现场判,结果按 bundle id 缓存;写死的四家不走这一步。
func TestBrowserScriptFamilyUsesTrustedDetection(t *testing.T) {
	saved := features()
	savedDetect := detectBrowserScriptFamily
	t.Cleanup(func() {
		setFeatures(saved)
		detectBrowserScriptFamily = savedDetect
		browserFamilyMu.Lock()
		browserFamilyCache = map[string]string{}
		browserFamilyMu.Unlock()
	})
	browserFamilyMu.Lock()
	browserFamilyCache = map[string]string{}
	browserFamilyMu.Unlock()
	featuresRef().TrustedPlayers = map[string]string{"com.vivaldi.Vivaldi": "Vivaldi"}
	calls := map[string]int{}
	detectBrowserScriptFamily = func(id string) string {
		calls[id]++
		if id == "com.vivaldi.Vivaldi" {
			return "chromium"
		}
		return "safari"
	}
	if got := browserScriptFamily("com.vivaldi.Vivaldi"); got != "chromium" {
		t.Fatalf("信任的 Vivaldi 该判成 chromium,得到 %q", got)
	}
	if got := browserScriptFamily("com.vivaldi.Vivaldi"); got != "chromium" || calls["com.vivaldi.Vivaldi"] != 1 {
		t.Fatalf("第二次该走缓存,得到 %q,判了 %d 次", got, calls["com.vivaldi.Vivaldi"])
	}
	if got := browserScriptFamily("com.operasoftware.Opera"); got != "" || calls["com.operasoftware.Opera"] != 0 {
		t.Fatalf("没信任的浏览器不该现场判,得到 %q,判了 %d 次", got, calls["com.operasoftware.Opera"])
	}
	for _, id := range []string{"com.google.Chrome", "com.brave.Browser"} {
		if got := browserScriptFamily(id); got != "chromium" || calls[id] != 0 {
			t.Fatalf("写死名单里的 %s 不该走现场判定,得到 %q", id, got)
		}
	}
	// 信任的浏览器接进队列预取:Vivaldi 里的 YouTube Music 标签页照样读。
	oldYT := ytmusicQueueScript
	t.Cleanup(func() { ytmusicQueueScript = oldYT })
	var asked string
	ytmusicQueueScript = func(bundleID, family string) (string, bool) {
		asked = bundleID + "/" + family
		return ytmusicQueueRaw(
			[]string{"1", "Miree", "Suchmos", "THE BAY", "4:03", "a"},
			[]string{"0", "Okay, Goodbye", "Fujii Kaze", "Prema", "4:00", "b"},
		), true
	}
	got, ok := upcomingFromQueue("Suchmos", "Miree", "THE BAY", "com.vivaldi.Vivaldi", 243, 5)
	if !ok || len(got) != 1 || asked != "com.vivaldi.Vivaldi/chromium" {
		t.Fatalf("信任的 Vivaldi 该读得到队列,得到 ok=%v asked=%q %+v", ok, asked, got)
	}
}

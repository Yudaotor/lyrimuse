package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 一个字段格式写错,不该连累其它字段,更不该让进程起不来。
// 原来 loadConfig 是一次严格 Unmarshal + main.go 的 log.Fatalf,而 collector 挂的是
// KeepAlive 的 LaunchAgent —— 一个 webhook 字段写错就是无限崩溃重启,悬浮歌词整个不亮。
func TestLoadConfigSkipsOnlyTheBadField(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	// bundle_ids 本该是数组,这里写成字符串。
	body := `{
	  "listenbrainz_token": "tok",
	  "listenbrainz_user": "someone",
	  "bundle_ids": "com.apple.Music",
	  "bark_url": "https://example.invalid/push"
	}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("坏字段不该让 loadConfig 失败: %v", err)
	}
	if cfg.Token != "tok" || cfg.User != "someone" {
		t.Errorf("好字段被连累了: token=%q user=%q", cfg.Token, cfg.User)
	}
	if cfg.NotificationWebhookURL != "https://example.invalid/push" {
		t.Errorf("坏字段之后的字段也要生效, got %q", cfg.NotificationWebhookURL)
	}
	// 坏字段退回默认值,而不是留下半解析的状态。
	if len(cfg.BundleIDs) != 1 || cfg.BundleIDs[0] != "com.apple.Music" {
		t.Errorf("bundle_ids 应该回落到默认值, got %v", cfg.BundleIDs)
	}
	if len(cfg.loadIssues) != 1 {
		t.Fatalf("应该正好记下一条问题, got %v", cfg.loadIssues)
	}
	if !strings.Contains(cfg.loadIssues[0], "bundle_ids") {
		t.Errorf("问题描述要点名是哪个字段, got %q", cfg.loadIssues[0])
	}
}

// 整份文件语法就坏了(少个引号/括号)时,没有字段边界可言,但仍然要起得来。
func TestLoadConfigSurvivesBrokenSyntax(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(`{"listenbrainz_token": "tok",`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("语法坏掉也不该失败(否则 KeepAlive 下就是崩溃循环): %v", err)
	}
	if len(cfg.loadIssues) == 0 {
		t.Error("必须留下一条问题说明,否则用户无从知道配置没生效")
	}
	// 默认值仍然要填好,collector 才跑得起来。
	if cfg.APIRoot == "" || len(cfg.BundleIDs) == 0 || cfg.NotificationPlatform == "" {
		t.Errorf("默认值没填: apiRoot=%q bundleIDs=%v platform=%q",
			cfg.APIRoot, cfg.BundleIDs, cfg.NotificationPlatform)
	}
}

// 配置里有 token / secret / session key,任何一个都不该出现在日志里 ——
// loadIssues 是直接 log.Printf 出去的(main.go),而日志会被诊断导出打包带走。
func TestLoadConfigIssuesNeverLeakSecrets(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	const secret = "s3cr3t-do-not-log-me"
	// 把敏感字段写成错误类型,强制它们进 issue 列表。
	body := `{
	  "listenbrainz_token": {"nested": "` + secret + `"},
	  "lastfm_scrobble_secret": ["` + secret + `"],
	  "lastfm_scrobble_session_key": 12345
	}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.loadIssues) != 3 {
		t.Fatalf("三个字段都该被跳过, got %v", cfg.loadIssues)
	}
	for _, issue := range cfg.loadIssues {
		if strings.Contains(issue, secret) {
			t.Errorf("问题描述泄露了配置值: %q", issue)
		}
	}
}

// 配置文件不存在是完全正常的(全默认跑),不是错误,也不该留下问题记录。
func TestLoadConfigMissingFileIsNotAnIssue(t *testing.T) {
	cfg, err := loadConfig(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatalf("配置不存在不该报错: %v", err)
	}
	if len(cfg.loadIssues) != 0 {
		t.Errorf("不存在的配置不该产生问题记录, got %v", cfg.loadIssues)
	}
	if cfg.APIRoot != "https://api.listenbrainz.org" {
		t.Errorf("默认 apiRoot 没填, got %q", cfg.APIRoot)
	}
}

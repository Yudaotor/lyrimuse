package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// 叠法跟 App 的 CredentialVault.overlay 读同一份样例对拍。
func TestCredentialVaultOverlayVectors(t *testing.T) {
	raw, err := os.ReadFile("testdata/credentialvault/overlay.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cases []struct {
			Name  string          `json:"name"`
			File  json.RawMessage `json:"file"`
			Vault json.RawMessage `json:"vault"`
			Want  json.RawMessage `json:"want"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil || len(doc.Cases) == 0 {
		t.Fatalf("样例读不出来: %v", err)
	}
	for _, c := range doc.Cases {
		var v credentialVault
		if err := json.Unmarshal(c.Vault, &v); err != nil {
			t.Fatalf("%s: vault %v", c.Name, err)
		}
		var got, want any
		if err := json.Unmarshal(overlayCredentials(c.File, v), &got); err != nil {
			t.Fatalf("%s: 叠完不是 JSON: %v", c.Name, err)
		}
		_ = json.Unmarshal(c.Want, &want)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s:\n got %v\nwant %v", c.Name, got, want)
		}
	}
}

func TestCredentialVaultOverlayLeavesUnreadableFileAlone(t *testing.T) {
	v := credentialVault{Config: map[string]json.RawMessage{"listenbrainz_token": json.RawMessage(`"v"`)}}
	for _, data := range []string{`{"listenbrainz_token": "f", oops`, `[1,2]`} {
		if got := string(overlayCredentials([]byte(data), v)); got != data {
			t.Errorf("读不懂的文件应原样交给 configFromBytes,得到 %q", got)
		}
	}
	var top map[string]string
	if json.Unmarshal(overlayCredentials(nil, v), &top) != nil || top["listenbrainz_token"] != "v" {
		t.Error("文件不存在时也该叠上保险箱")
	}
}

// loadConfig 叠上保险箱,凭据照常进 cfg、进脱敏表的口径不变;文件里的明文优先。
func TestLoadConfigOverlaysCredentialVault(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	stubCredentialVault(t, `{"config":{"listenbrainz_token":"vault-token","lastfm_scrobble_secret":"vault-secret"},"channels":{"a":{"url":"https://api.day.app/K"}}}`, nil)
	path := filepath.Join(dir, "config.json")
	writeConfigForTest(t, path, `{"listenbrainz_user":"u","lastfm_scrobble_secret":"file-secret","notification_channels":[{"id":"a","platform":"bark","url":"","enabled":true}]}`)
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Token != "vault-token" || cfg.LastfmScrobbleSecret != "file-secret" {
		t.Errorf("token=%q secret=%q,应为保险箱的 token、文件里的 secret", cfg.Token, cfg.LastfmScrobbleSecret)
	}
	if chs := configNotifyChannels(cfg); len(chs) != 1 || chs[0].URL != "https://api.day.app/K" {
		t.Errorf("渠道地址没从保险箱补上: %+v", chs)
	}
}

// 热重读同样叠保险箱:App 改凭据是先写钥匙串、再写 config.json,文件一变就重读两者。
func TestLiveConfigReloadOverlaysCredentialVault(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	path := filepath.Join(dir, "config.json")
	vault := `{"config":{"listenbrainz_token":"t1"}}`
	stub := stubCredentialVault(t, vault, nil)
	resetLiveConfigForTest(t)
	writeConfigForTest(t, path, `{"listenbrainz_user":"u"}`)
	setLiveConfigAt(path, configFromBytes(nil), nil)
	configCheckedAt.Store(0)
	if got := liveConfig(); got.Token != "t1" {
		t.Fatalf("热重读拿到 token %q,应为保险箱的 t1", got.Token)
	}
	stub.data = `{"config":{"listenbrainz_token":"t2"}}`
	writeConfigForTest(t, path, `{"listenbrainz_user":"u2"}`)
	configCheckedAt.Store(0)
	if got := liveConfig(); got.Token != "t2" || got.User != "u2" {
		t.Errorf("文件变了之后 token=%q user=%q,应为 t2 / u2", got.Token, got.User)
	}
}

// 保险箱按 config.json 与令牌文件的 mtime/size 缓存;读失败沿用上一次的,过一阵才再试。
func TestCurrentCredentialVaultCachesAndKeepsLastGoodOnFailure(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	stub := stubCredentialVault(t, `{"config":{"listenbrainz_token":"t1"}}`, nil)
	path := filepath.Join(dir, "config.json")
	writeConfigForTest(t, path, `{}`)
	token := func() string { return string(currentCredentialVault().Config["listenbrainz_token"]) }
	if token() != `"t1"` || token() != `"t1"` || stub.calls != 1 {
		t.Fatalf("文件没变时只该读一次钥匙串,读了 %d 次", stub.calls)
	}
	stub.data = `{"config":{"listenbrainz_token":"t2"}}`
	writeConfigForTest(t, path, `{"a":1}`)
	if token() != `"t2"` || stub.calls != 2 {
		t.Fatalf("config.json 变了应重读,读了 %d 次", stub.calls)
	}
	stub.err = errors.New("locked")
	writeConfigForTest(t, path, `{"a":2}`)
	if token() != `"t2"` {
		t.Error("读失败时应沿用上一次读到的")
	}
	writeConfigForTest(t, path, `{"a":3}`)
	if token(); stub.calls != 3 {
		t.Errorf("读失败后 %s 内不该再起 security,读了 %d 次", credentialVaultRetry, stub.calls)
	}
}

// 接连读失败时重试间隔逐次翻倍、封顶;重试之前 config.json 变了、离上一次读也过了一个基本间隔就提前读。
func TestCredentialVaultBacksOffOnRepeatedFailures(t *testing.T) {
	if got := []time.Duration{credentialVaultRetryDelay(1), credentialVaultRetryDelay(2), credentialVaultRetryDelay(3), credentialVaultRetryDelay(40)}; got[0] != credentialVaultRetry || got[1] != 2*credentialVaultRetry || got[2] != 4*credentialVaultRetry || got[3] != credentialVaultMaxRetry {
		t.Fatalf("间隔 = %v", got)
	}
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	stub := stubCredentialVault(t, "", errors.New("timed out"))
	path := filepath.Join(dir, "config.json")
	writeConfigForTest(t, path, `{}`)
	for i := 0; i < 3; i++ {
		currentCredentialVault()
		setCredentialVaultRetryAtForTest(time.Now().Add(-time.Second))
	}
	c := &credentialVaultCache
	if c.failures != 3 || stub.calls != 3 {
		t.Fatalf("接连失败 3 次: failures=%d calls=%d", c.failures, stub.calls)
	}
	currentCredentialVault()
	if wait := time.Until(c.retryAt); wait < 7*credentialVaultRetry || wait > 8*credentialVaultRetry {
		t.Errorf("第 4 次失败后应等 8 个基本间隔,等 %s", wait)
	}
	writeConfigForTest(t, path, `{"a":1}`)
	currentCredentialVault()
	if stub.calls != 4 {
		t.Errorf("刚读过就不因文件变了再读,读了 %d 次", stub.calls)
	}
	c.attemptAt = time.Now().Add(-credentialVaultRetry - time.Second)
	stub.err = nil
	stub.data = `{"config":{"listenbrainz_token":"t"}}`
	if got := string(currentCredentialVault().Config["listenbrainz_token"]); got != `"t"` || c.failures != 0 {
		t.Errorf("文件变了、离上次读过了基本间隔应提前读: token=%s failures=%d", got, c.failures)
	}
}

// App 报钥匙串锁着(提示文件、写它的进程还在)时不起 security;提示是已经没了的进程留下的不算。
func TestKeychainLockedHintSkipsSecurity(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	saved := credentialVaultSecurity
	credentialVaultSecurity = filepath.Join(dir, "no-such-security")
	t.Cleanup(func() { credentialVaultSecurity = saved })
	hint := filepath.Join(dir, keychainLockedHintName)
	if err := os.WriteFile(hint, []byte(fmt.Sprintf(`{"pid":%d}`, os.Getpid())), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readCredentialVaultFromKeychain(); !errors.Is(err, errKeychainLocked) {
		t.Fatalf("有提示、进程还在: err = %v,应为 errKeychainLocked", err)
	}
	gone := exec.Command("/usr/bin/true")
	if err := gone.Run(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hint, []byte(fmt.Sprintf(`{"pid":%d}`, gone.Process.Pid)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readCredentialVaultFromKeychain(); errors.Is(err, errKeychainLocked) || err == nil {
		t.Fatalf("进程已经没了的提示不算,应去起 security(这里是个不存在的路径,报错),得到 %v", err)
	}

	stub := stubCredentialVault(t, "", errKeychainLocked)
	writeConfigForTest(t, filepath.Join(dir, "config.json"), `{}`)
	for i := 0; i < 3; i++ {
		currentCredentialVault()
		setCredentialVaultRetryAtForTest(time.Now().Add(-time.Second))
	}
	if c := &credentialVaultCache; c.failures != 0 || !c.locked || stub.calls != 3 {
		t.Errorf("锁着不算失败、不加长间隔: failures=%d locked=%v calls=%d", c.failures, c.locked, stub.calls)
	}
}

// 提示文件名跟 App 那边(KeychainLock.hintFileName)一致。
func TestKeychainLockedHintNameMatchesApp(t *testing.T) {
	src, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Util/KeychainLock.swift")
	if err != nil {
		t.Skipf("读不到 App 源码: %v", err)
	}
	if !strings.Contains(string(src), `hintFileName = "`+keychainLockedHintName+`"`) {
		t.Errorf("KeychainLock.hintFileName 不是 %q", keychainLockedHintName)
	}
}

// 令牌文件里没有令牌时取保险箱的;旧版本写在文件里的照认。
func TestAppleMusicUserTokenFromCredentialVault(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	stub := stubCredentialVault(t, `{"media_user_token":"vault-mut"}`, nil)
	tokenPath := applemusicUserTokenPath()
	writeConfigForTest(t, tokenPath, `{"storefront":"cn","saved_at":1800000000}`)
	if tok, sf := applemusicLoadUserToken(); tok != "vault-mut" || sf != "cn" {
		t.Errorf("token=%q storefront=%q,应为保险箱的令牌和文件里的店面", tok, sf)
	}
	// 重新连接:App 先把新令牌写进钥匙串,再重写令牌文件;文件一变就重读钥匙串。
	stub.data = `{"media_user_token":"vault-mut-2"}`
	writeConfigForTest(t, tokenPath, `{"storefront":"cn","saved_at":1800000100}`)
	if tok, _ := applemusicLoadUserToken(); tok != "vault-mut-2" {
		t.Errorf("令牌文件变了应重读钥匙串,得到 %q", tok)
	}
	writeConfigForTest(t, tokenPath, `{"media_user_token":"file-mut","storefront":"jp","saved_at":1800000001}`)
	if tok, _ := applemusicLoadUserToken(); tok != "file-mut" {
		t.Errorf("文件里有令牌时应以文件为准,得到 %q", tok)
	}
	if err := os.Remove(tokenPath); err != nil {
		t.Fatal(err)
	}
	if tok, _ := applemusicLoadUserToken(); tok != "" {
		t.Errorf("连接记录文件没了就是没连,不该只凭保险箱里的令牌算连上,得到 %q", tok)
	}
}

// 真起 /usr/bin/security,读一份临时钥匙串:App 那边怎么写(security -i、base64),这边就怎么读。
func TestReadCredentialVaultFromRealKeychain(t *testing.T) {
	if _, err := os.Stat("/usr/bin/security"); err != nil {
		t.Skip("没有 /usr/bin/security")
	}
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	keychain := filepath.Join(t.TempDir(), "vault-test.keychain-db")
	if out, err := exec.Command("/usr/bin/security", "create-keychain", "-p", "test", keychain).CombinedOutput(); err != nil {
		t.Skipf("建不了临时钥匙串: %v %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("/usr/bin/security", "delete-keychain", keychain).Run() })
	old := credentialVaultKeychain
	credentialVaultKeychain = keychain
	t.Cleanup(func() { credentialVaultKeychain = old })

	if data, err := readCredentialVaultFromKeychain(); data != nil || err != nil {
		t.Fatalf("没有条目时应为 nil, nil,得到 %q %v", data, err)
	}
	payload := `{"config":{"listenbrainz_token":"t"}}`
	line := `add-generic-password -U -s "` + credentialVaultService() + `" -a "` + filepath.Clean(dir) + `" -w ` +
		base64.StdEncoding.EncodeToString([]byte(payload)) + ` "` + keychain + `"` + "\n"
	cmd := exec.Command("/usr/bin/security", "-i")
	cmd.Stdin = strings.NewReader(line)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("写条目失败: %v %s", err, out)
	}
	data, err := readCredentialVaultFromKeychain()
	if err != nil || string(data) != payload {
		t.Errorf("读回 %q %v,应为 %q", data, err, payload)
	}
}

// 默认位置的新账号上没有条目时读以前的账号(App 还没把它搬过来);新账号上有就只认新的。
func TestReadCredentialVaultFallsBackToPreviousAccount(t *testing.T) {
	if _, err := os.Stat("/usr/bin/security"); err != nil {
		t.Skip("没有 /usr/bin/security")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	data := filepath.Join(home, "Library", "Application Support", appBundleID())
	t.Setenv("LYRIMUSE_CONFIG_DIR", data)
	keychain := filepath.Join(t.TempDir(), "vault-test.keychain-db")
	if out, err := exec.Command("/usr/bin/security", "create-keychain", "-p", "test", keychain).CombinedOutput(); err != nil {
		t.Skipf("建不了临时钥匙串: %v %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("/usr/bin/security", "delete-keychain", keychain).Run() })
	old := credentialVaultKeychain
	credentialVaultKeychain = keychain
	t.Cleanup(func() { credentialVaultKeychain = old })
	write := func(account, payload string) {
		t.Helper()
		line := `add-generic-password -U -s "` + credentialVaultService() + `" -a "` + account + `" -w ` +
			base64.StdEncoding.EncodeToString([]byte(payload)) + ` "` + keychain + `"` + "\n"
		cmd := exec.Command("/usr/bin/security", "-i")
		cmd.Stdin = strings.NewReader(line)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("写条目失败: %v %s", err, out)
		}
	}

	write(filepath.Join(home, ".config", clientName), `{"config":{"listenbrainz_token":"old"}}`)
	if data, err := readCredentialVaultFromKeychain(); err != nil || string(data) != `{"config":{"listenbrainz_token":"old"}}` {
		t.Errorf("新账号没有条目时应读到以前账号的,得到 %q %v", data, err)
	}
	write(data, `{"config":{"listenbrainz_token":"new"}}`)
	if got, err := readCredentialVaultFromKeychain(); err != nil || string(got) != `{"config":{"listenbrainz_token":"new"}}` {
		t.Errorf("新账号有条目时应只认新的,得到 %q %v", got, err)
	}
}

// 钥匙串锁着时 security 会一直等用户解锁:限时到了就放弃,不卡住调用方。
func TestReadCredentialVaultTimesOut(t *testing.T) {
	script := filepath.Join(t.TempDir(), "security")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nsleep 5\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	oldBin, oldTimeout := credentialVaultSecurity, credentialVaultTimeout
	credentialVaultSecurity, credentialVaultTimeout = script, 100*time.Millisecond
	t.Cleanup(func() { credentialVaultSecurity, credentialVaultTimeout = oldBin, oldTimeout })
	start := time.Now()
	_, err := readCredentialVaultFromKeychain()
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Errorf("应报超时,得到 %v", err)
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("超时后还等了 %s", elapsed)
	}
}

type credentialVaultStub struct {
	data  string
	err   error
	calls int
}

// stubCredentialVault 把保险箱换成内存里的一份,并清掉缓存;用例结束换回 TestMain 那个「没有条目」。
func stubCredentialVault(t *testing.T, data string, err error) *credentialVaultStub {
	t.Helper()
	stub := &credentialVaultStub{data: data, err: err}
	old := credentialVaultRead
	credentialVaultRead = func() ([]byte, error) {
		stub.calls++
		if stub.err != nil {
			return nil, stub.err
		}
		return []byte(stub.data), nil
	}
	resetCredentialVaultCache()
	t.Cleanup(func() {
		credentialVaultRead = old
		resetCredentialVaultCache()
	})
	return stub
}

// resetCredentialVaultCache 让下一次 currentCredentialVault 重新读。
func resetCredentialVaultCache() {
	c := &credentialVaultCache
	c.Lock()
	c.stamp, c.vault, c.retryAt, c.attemptAt, c.failed, c.failures, c.locked = "", credentialVault{}, time.Time{}, time.Time{}, false, 0, false
	c.Unlock()
}

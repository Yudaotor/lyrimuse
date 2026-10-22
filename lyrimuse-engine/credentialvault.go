package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// 凭据保险箱:账号 token、推送地址与密钥、Apple Music 用户令牌存在登录钥匙串的一个条目里,不在 config.json。
// App 写(LyrimuseCore CredentialVault),这边只读。两边都经 /usr/bin/security 读写:条目的访问控制只信任这个
// Apple 签名的程序,App 更新、换签名都不弹授权框;引擎不开 cgo,也只能这样读。
//
// 条目:服务名 `<bundle id>.credentials`,账号是配置目录的绝对路径(另起一份配置目录跑的引擎读不到正式那份),
// 内容是一份 JSON 的 base64:
//
//	{"config": {<credentialConfigKeys 里的键>: 值}, "channels": {<渠道 id>: {"url": …, "secret": …}}, "media_user_token": "…"}
//
// 读配置时叠到 config.json 上(overlayCredentials):文件里那一项缺失或为空才取保险箱的;文件里有值(旧版本写的、
// 手改的、刚导入的)以文件为准,App 下次启动再把它挪进钥匙串。叠法跟 App 的 CredentialVault.overlay 一致,
// 两边读同一份 testdata/credentialvault/overlay.json 对拍。见 15 章决策 73。

// credentialConfigKeys:config.json 里算凭据、存进保险箱的顶层键。跟 App 的 CredentialVault.configKeys 逐项一致。
var credentialConfigKeys = map[string]bool{
	"listenbrainz_token": true, "state_relay_token": true,
	"lastfm_api_key": true, "lastfm_scrobble_api_key": true, "lastfm_scrobble_secret": true, "lastfm_scrobble_session_key": true,
	"bark_url": true, "notification_webhook_urls": true, "dingtalk_sign_secret": true, "feishu_sign_secret": true,
}

type credentialVault struct {
	Config         map[string]json.RawMessage        `json:"config,omitempty"`
	Channels       map[string]credentialVaultChannel `json:"channels,omitempty"`
	MediaUserToken string                            `json:"media_user_token,omitempty"`
}

type credentialVaultChannel struct {
	URL    string `json:"url,omitempty"`
	Secret string `json:"secret,omitempty"`
}

// 钥匙串锁着时 security 会等用户解锁、一直不返回,所以读要限时;读不到就沿用上一次读到的,过一阵再试。
var (
	credentialVaultSecurity = "/usr/bin/security"
	// credentialVaultKeychain 为空读默认搜索列表(登录钥匙串);测试指到临时钥匙串文件。
	credentialVaultKeychain = ""
	credentialVaultTimeout  = 5 * time.Second
	credentialVaultRetry    = time.Minute
	// credentialVaultRead 取保险箱的 JSON 字节,没有条目返回 nil, nil。测试换成假的(TestMain)。
	credentialVaultRead = readCredentialVaultFromKeychain
)

func credentialVaultService() string { return appBundleID() + ".credentials" }

func readCredentialVaultFromKeychain() ([]byte, error) {
	dir := configDir()
	if dir == "" {
		return nil, nil
	}
	args := []string{"find-generic-password", "-s", credentialVaultService(), "-a", filepath.Clean(dir), "-w"}
	if credentialVaultKeychain != "" {
		args = append(args, credentialVaultKeychain)
	}
	ctx, cancel := context.WithTimeout(context.Background(), credentialVaultTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, credentialVaultSecurity, args...).Output()
	if ctx.Err() != nil {
		return nil, fmt.Errorf("keychain read timed out after %s (keychain locked?)", credentialVaultTimeout)
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 44 { // errSecItemNotFound
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("keychain read: %w", err)
	}
	data, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	if err != nil {
		return nil, fmt.Errorf("keychain item is not base64: %w", err)
	}
	return data, nil
}

// credentialVaultCache:App 改保险箱之后一定接着写 config.json 或令牌文件,所以按这两份文件的 mtime/size 认
// 「保险箱可能变了」,没变就不再起 security。
var credentialVaultCache struct {
	sync.Mutex
	stamp   string
	vault   credentialVault
	retryAt time.Time
	// failed:最近一次读失败,手上的是更早读到的(或空的)。
	failed bool
}

func credentialVaultStamp() string {
	var b strings.Builder
	for _, name := range []string{"config.json", clientName + "-applemusic-token.json"} {
		if st, err := os.Stat(configFilePath(name)); err == nil {
			fmt.Fprintf(&b, "%d/%d;", st.ModTime().UnixNano(), st.Size())
		} else {
			b.WriteString("-;")
		}
	}
	return b.String()
}

// currentCredentialVault 取这一刻的保险箱。读失败(钥匙串锁着、超时)时沿用上一次读到的,credentialVaultRetry 之后再试。
func currentCredentialVault() credentialVault {
	stamp := credentialVaultStamp()
	c := &credentialVaultCache
	c.Lock()
	defer c.Unlock()
	if stamp == c.stamp || time.Now().Before(c.retryAt) {
		return c.vault
	}
	data, err := credentialVaultRead()
	var v credentialVault
	if err == nil && data != nil {
		err = json.Unmarshal(data, &v)
	}
	if err != nil {
		log.Printf("credentials: keychain unreadable (%v), keeping the credentials read before, retry in %s", err, credentialVaultRetry)
		c.retryAt = time.Now().Add(credentialVaultRetry)
		c.failed = true
		return c.vault
	}
	c.stamp, c.vault, c.retryAt, c.failed = stamp, v, time.Time{}, false
	return v
}

// credentialVaultRetryDue:上一次读保险箱失败、已到重试时刻。热重读据此在 config.json 没变时也重叠一次,
// 否则启动那一下钥匙串锁着,之后解锁了凭据也要等下一次改设置才补上。
func credentialVaultRetryDue() bool {
	c := &credentialVaultCache
	c.Lock()
	defer c.Unlock()
	return c.failed && !time.Now().Before(c.retryAt)
}

func credentialVaultFailed() bool {
	c := &credentialVaultCache
	c.Lock()
	defer c.Unlock()
	return c.failed
}

// overlayCredentials 把保险箱叠到 config.json 的字节上:凭据键缺失或为空时取保险箱的,渠道按 id 补地址和密钥。
// 文件读不懂(不是 JSON 对象)时原样返回,交给 configFromBytes 照常容错。data 为 nil 表示文件不存在。
func overlayCredentials(data []byte, v credentialVault) []byte {
	if len(v.Config) == 0 && len(v.Channels) == 0 {
		return data
	}
	top := map[string]json.RawMessage{}
	if data != nil {
		if err := json.Unmarshal(data, &top); err != nil || top == nil {
			return data
		}
	}
	changed := false
	for key, value := range v.Config {
		if credentialConfigKeys[key] && credentialRawBlank(top[key]) && !credentialRawBlank(value) {
			top[key] = value
			changed = true
		}
	}
	if raw, ok := top["notification_channels"]; ok && len(v.Channels) > 0 {
		var channels []map[string]json.RawMessage
		if json.Unmarshal(raw, &channels) == nil {
			filled := false
			for _, ch := range channels {
				var id string
				if ch == nil || json.Unmarshal(ch["id"], &id) != nil {
					continue
				}
				saved, ok := v.Channels[id]
				if !ok {
					continue
				}
				for field, value := range map[string]string{"url": saved.URL, "secret": saved.Secret} {
					if value != "" && credentialRawBlank(ch[field]) {
						ch[field], _ = json.Marshal(value)
						filled = true
					}
				}
			}
			if filled {
				if b, err := json.Marshal(channels); err == nil {
					top["notification_channels"] = b
					changed = true
				}
			}
		}
	}
	if !changed {
		return data
	}
	out, err := json.Marshal(top)
	if err != nil {
		return data
	}
	return out
}

// credentialRawBlank:缺失、null、空白字符串、空对象都算空。
func credentialRawBlank(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return strings.TrimSpace(s) == ""
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) == nil {
		return len(m) == 0
	}
	return false
}

package main

import (
	"os"
	"path/filepath"
	"time"
)

// configDir 是引擎的数据目录:config.json、features、enrich 缓存、歌词、设备封面、收听日志、状态文件、单实例锁都在它下面
// (删了只会重新联网或重算的查询缓存在 cacheDir())。常驻路径以 `-config` 的目录为准(默认值就是这里),一次性子命令直接取这里。
//
// 环境变量 LYRIMUSE_CONFIG_DIR(绝对路径)优先:App 侧 EngineServiceManager 写 launchd plist、以及 spawn 每个一次性子命令时
// 都会传(机制保留,别再靠 os.UserHomeDir 自己拼路径)。没有环境变量时跟 App 同一条规则(LyrimuseCore 的 StorageLayout.activeDataDir):
// 旧目录 ~/.config/lyrimuse 是软链接就一直用它;不是目录就用新目录 ~/Library/Application Support/<bundle id>;新目录有搬迁标记
// 就用新目录;旧目录有数据、新目录没有(App 还没搬)用旧目录;其余用新目录。见 14 章决策 136。
//
// 没有环境变量、又拿不到家目录时返回空串,调用方按原来的方式报错(main.go 常驻路径直接 fatalExit)。
func configDir() string {
	if v := os.Getenv("LYRIMUSE_CONFIG_DIR"); v != "" && filepath.IsAbs(v) {
		return v
	}
	legacy, data, _, ok := storageRoots()
	if !ok {
		return ""
	}
	fi, err := os.Lstat(legacy)
	if err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return legacy
	}
	if err != nil || !fi.IsDir() {
		return data
	}
	if _, err := os.Lstat(filepath.Join(data, storageMigrationMarker)); err == nil {
		return data
	}
	if hasLyrimuseData(legacy) && !hasLyrimuseData(data) {
		return legacy
	}
	return data
}

// storageMigrationMarker:App 搬迁时写的标记(LyrimuseCore StorageMigration.markerName)。
const storageMigrationMarker = "lyrimuse-storage-migration.json"

// hasLyrimuseData:目录里有搬迁标记、账号配置、功能开关、偏好镜像、歌词主缓存、听歌记录之一。跟 StorageLayout.dataSignatureFiles
// 同一份名单。
func hasLyrimuseData(dir string) bool {
	for _, name := range []string{
		storageMigrationMarker, "config.json", clientName + "-features.json", clientName + "-app-settings.json",
		clientName + "-enrich-cache.json", clientName + "-listens.jsonl",
	} {
		if _, err := os.Lstat(filepath.Join(dir, name)); err == nil {
			return true
		}
	}
	return false
}

// storageRoots:旧数据目录、新数据目录、缓存目录的默认位置。拿不到家目录时 ok 为 false。
func storageRoots() (legacy, data, caches string, ok bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", "", false
	}
	return filepath.Join(home, ".config", clientName),
		filepath.Join(home, "Library", "Application Support", appBundleID()),
		filepath.Join(home, "Library", "Caches", appBundleID()),
		true
}

// cacheDir 放删了只会重新联网或重算的查询缓存(名单跟 LyrimuseCore 的 StorageLayout.cacheFileNames 一致)。环境变量
// LYRIMUSE_CACHE_DIR(绝对路径)优先,App 总会传;没传、却显式给了 LYRIMUSE_CONFIG_DIR 的(测试、另起一份数据目录排查)
// 跟数据目录放在一起,不去碰默认的 ~/Library/Caches;都没有时是 ~/Library/Caches/<bundle id>。
func cacheDir() string {
	if v := os.Getenv("LYRIMUSE_CACHE_DIR"); v != "" && filepath.IsAbs(v) {
		return v
	}
	if v := os.Getenv("LYRIMUSE_CONFIG_DIR"); v != "" && filepath.IsAbs(v) {
		return v
	}
	_, _, caches, ok := storageRoots()
	if !ok {
		return ""
	}
	return caches
}

// cacheFilePath 是缓存目录下的一个文件。
func cacheFilePath(name string) string {
	return filepath.Join(cacheDir(), name)
}

// alignConfigDirWithFlag:常驻进程带了 -config、而它的目录不是 configDir() 时,让 configDir() 也指过去
// (经 LYRIMUSE_CONFIG_DIR)。常驻路径的落盘有两套写法 —— 单实例锁、features、缓存按 -config 的目录,
// 本地缓存可读性、补空请求 / 状态、署名纠正这几份走 configDir() —— 不一致时,手动带 -config 起的排查
// 实例拿的不是正式实例那把锁,两个都能起来,还会删改、认领正式目录下的状态文件和 App 投来的请求。
func alignConfigDirWithFlag(cfgPath, defaultDir string) {
	dir, err := filepath.Abs(filepath.Dir(cfgPath))
	if err != nil || dir == defaultDir {
		return
	}
	_ = os.Setenv("LYRIMUSE_CONFIG_DIR", dir)
}

// backupDir 是引擎动手改数据之前留的备份:数据目录下 backups/<时刻>-<用途>。放在数据目录里,别放它的上一层 ——
// 那是 ~/Library/Application Support,别的程序也在用。旧版本写在 ~/.config/lyrimuse-backups,那里已有的不搬
// (song-entity-share.json 里记着它们的绝对路径)。拿不到数据目录时返回空串。
func backupDir(now time.Time, purpose string) string {
	dir := configDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "backups", now.Format("20060102-150405")+"-"+purpose)
}

// configFilePath 是配置目录下的一个文件(或子目录)。
func configFilePath(name string) string {
	return filepath.Join(configDir(), name)
}

// appBundleID 是「本引擎所属的那个 App」的 bundle id —— companion launch 拿它 `open -b`。环境变量
// LYRIMUSE_APP_BUNDLE_ID 优先(App 侧跟另外两个变量一起写进 plist / 子进程环境),缺省是正式版
// (这一层是给别的 bundle id 的构建用的,回退 Dev 变体后没有这种构建,机制保留)。
func appBundleID() string {
	if v := os.Getenv("LYRIMUSE_APP_BUNDLE_ID"); v != "" {
		return v
	}
	return "me.yudaotor.lyrimuse"
}

// logFilePath 是常驻进程日志文件:launchd 的 StandardOutPath/StandardErrorPath 指向它,引擎自己也打开它写
// 并按大小轮转(logsink.go / logrotate.go)。环境变量 LYRIMUSE_LOG_FILE(绝对路径)优先,理由同上;Swift 侧对应
// LyrimuseCore 的 LogFiles.engine。拿不到家目录时返回空串,调用方据此放弃轮转、退回 stderr,不阻塞启动。
func logFilePath() string {
	if v := os.Getenv("LYRIMUSE_LOG_FILE"); v != "" && filepath.IsAbs(v) {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library/Logs", clientName+".log")
}

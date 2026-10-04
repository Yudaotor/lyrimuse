package main

import (
	"log"
	"path/filepath"
	"strings"
	"sync"
)

// 启动时一连串辅助缓存的「载入了多少条」合成一行,不再一份文件一行:引擎每次重启(装机、升级、
// 登录)都要载十来份,逐份记的话每次启动光这一类就十几行。主缓存(loadEnrichCache)另有一行,不走这里。
//
// beginCacheLoadBatch / endCacheLoadBatch 之间的 noteCacheLoaded 先攒着,end 时写成一行;不在批里(命令行
// 子命令、运行中重读)的当场写一行、带上文件路径。
var cacheLoadBatch struct {
	mu    sync.Mutex
	on    bool
	dir   string
	parts []string
}

func beginCacheLoadBatch(dir string) {
	cacheLoadBatch.mu.Lock()
	defer cacheLoadBatch.mu.Unlock()
	cacheLoadBatch.on, cacheLoadBatch.dir, cacheLoadBatch.parts = true, dir, nil
}

// noteCacheLoaded:path 那份缓存载入了,what 形如 "12 artist aliases"。
func noteCacheLoaded(path, what string) {
	cacheLoadBatch.mu.Lock()
	defer cacheLoadBatch.mu.Unlock()
	if cacheLoadBatch.on && filepath.Dir(path) == cacheLoadBatch.dir {
		cacheLoadBatch.parts = append(cacheLoadBatch.parts, what)
		return
	}
	log.Printf("cache: loaded %s from %s", what, path)
}

func endCacheLoadBatch() {
	cacheLoadBatch.mu.Lock()
	defer cacheLoadBatch.mu.Unlock()
	if len(cacheLoadBatch.parts) > 0 {
		log.Printf("cache: loaded %s from %s", strings.Join(cacheLoadBatch.parts, ", "), cacheLoadBatch.dir)
	}
	cacheLoadBatch.on, cacheLoadBatch.parts = false, nil
}

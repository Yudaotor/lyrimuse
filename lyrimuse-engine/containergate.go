package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// 由 App 拉起的子命令(手动搜歌词、测歌词源……)读别的 App 的私有容器时,系统把它算在 Lyrimuse 名下,
// 没有授权就弹「"Lyrimuse"想访问其他 App 的数据」;常驻引擎是 launchd 起的,被拒时不弹框。
// 所以子命令只读常驻引擎已经确认读得到的那几家的容器(状态文件里的 readable),别的容器一律当不存在、
// 退回网络解析。常驻引擎不设闸。见 02 章决策 237。
//
// 所有指向 `~/Library/Containers/<bundle id>/Data` 的路径都要经过 otherAppContainer,
// TestOtherAppContainerPathsGoThroughGate 扫源码守着。
var containerGate struct {
	sync.RWMutex
	on      bool
	allowed map[string]bool // 容器的 bundle id
}

// gateOtherAppContainers 由 main() 在子命令分流之前调用。statePath 是常驻引擎发布的 localCacheAccessState;
// 读不到(常驻引擎没在跑、还没探过、旧版)时所有容器都不读。
func gateOtherAppContainers(statePath string) {
	allowed := map[string]bool{}
	var state localCacheAccessState
	if data, err := os.ReadFile(statePath); err == nil && json.Unmarshal(data, &state) == nil {
		readable := map[string]bool{}
		for _, s := range state.Readable {
			readable[s] = true
		}
		for source, paths := range localCacheClientPaths() {
			if !readable[source] {
				continue
			}
			for _, p := range paths {
				if root := containerDataRoot(p); root != "" {
					allowed[filepath.Base(filepath.Dir(root))] = true
				}
			}
		}
	}
	containerGate.Lock()
	containerGate.on, containerGate.allowed = true, allowed
	containerGate.Unlock()
}

// otherAppContainer 原样返回 path,除非闸开着、path 在别的 App 的私有容器里、而那个容器不在放行名单上,这时返回 ""。
func otherAppContainer(path string) string {
	root := containerDataRoot(path)
	if root == "" {
		return path
	}
	containerGate.RLock()
	defer containerGate.RUnlock()
	if !containerGate.on || containerGate.allowed[filepath.Base(filepath.Dir(root))] {
		return path
	}
	return ""
}

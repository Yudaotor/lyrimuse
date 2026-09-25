package main

import (
	"fmt"
	"os"
)

// claimRequestFile 消费 App 投递的一次性请求文件:先把它改名认领到一个本进程独有的名字,再读、再删。
// 别写成「读原路径 → 删原路径」:App 恰好在这两步之间投递的新请求会被当成旧的一起删掉。认领之后才到的
// 请求原样留在原路径,下一轮再处理。文件不存在时返回 os.ErrNotExist 类错误(调用方当「没有请求」)。
func claimRequestFile(path string) ([]byte, error) {
	claimed := fmt.Sprintf("%s.claimed.%d", path, os.Getpid())
	if err := os.Rename(path, claimed); err != nil {
		return nil, err
	}
	defer os.Remove(claimed)
	return os.ReadFile(claimed)
}

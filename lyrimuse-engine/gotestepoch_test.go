package main

import (
	"os"
	"testing"
)

// LYRIMUSE_GO_TEST_EPOCH 不影响任何测试:go 把测试运行时读过的环境变量记进这个包测试结果的缓存键,
// scripts/commit-checks.sh 换一个值就让整套重跑、结果照样进缓存(带 -count=1 跑的结果不进缓存)。
// 只能在测试函数里读:TestMain 里 m.Run() 之前读的不算进去。
func TestGoTestEpochIsACacheInput(t *testing.T) {
	_ = os.Getenv("LYRIMUSE_GO_TEST_EPOCH")
}

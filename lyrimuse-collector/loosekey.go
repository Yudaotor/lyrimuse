package main

import "sync"

// loosenEnrichKey 的记忆化:同一个输入永远得到同一个宽松 key(繁简词典、异体字表、合 credit
// 分隔符都是启动时定下的常量),所以按输入字符串缓存结果是安全的,不需要跟着 enrichCache 的
// 写入点同步失效 —— 这正是 canonicalEnrichKey 头注里不愿维护索引的那个理由,这里绕开了它。
//
// 为什么要:canonicalEnrichKey / looseInflightKey 对整个缓存逐条算宽松 key。缓存涨到 8600 多条
// 之后,不记忆化时一次全表比对要 230 毫秒左右,而且全程持有 enrichMu;精确 key 查不到的曲目
// (桥接来的 iPhone 播放、换了拼法的歌)每次中继推送、每次预取查重都要走一遍,collector 常驻
// 十几到二十几的 CPU 就耗在这里。
//
// 上限只是防御:条目数超过 looseKeyMemoMax 就整张清掉重来。正常的规模是缓存条数加上这段时间
// 被拿来比对过的曲目名,远到不了。
const looseKeyMemoMax = 64 << 10

var (
	looseKeyMemoMu sync.RWMutex
	looseKeyMemo   = map[string]string{}
)

func loosenEnrichKey(key string) string {
	looseKeyMemoMu.RLock()
	v, ok := looseKeyMemo[key]
	looseKeyMemoMu.RUnlock()
	if ok {
		return v
	}
	v = loosenEnrichKeyUncached(key)
	looseKeyMemoMu.Lock()
	if len(looseKeyMemo) >= looseKeyMemoMax {
		looseKeyMemo = map[string]string{}
	}
	looseKeyMemo[key] = v
	looseKeyMemoMu.Unlock()
	return v
}

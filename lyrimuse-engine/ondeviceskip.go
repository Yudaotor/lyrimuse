package main

import (
	"sync"
	"time"
)

// onDeviceTranslateTimeout 端上翻译每组最多等多久,到点就杀掉 helper、这组交给网络翻译。
// 引擎是后台优先级的 launchd 任务,helper 跟着按后台优先级跑,机器一忙光问一句「语言包装了没有」
// 就可能要几十秒;不单独限时的话它会吃掉整首 90 秒的额度,网络两家来不及试(见 10 章决策 29)。
var onDeviceTranslateTimeout = 10 * time.Second

// onDeviceSkipFor 端上翻译走不通(语言包没装、限时内没答复)之后,同一种文字翻成同一目标语言多久之内不再起 helper。
const onDeviceSkipFor = 30 * time.Minute

// onDeviceSkips 记着哪几组「文字系统 → 目标语言」的端上翻译暂时走不通。按文字系统记:源语言由 helper 自己识别,
// 调用之前不知道。只在内存里,引擎重启就重新问一次。
var onDeviceSkips = &onDeviceSkipTable{until: map[onDeviceSkipKey]time.Time{}}

type onDeviceSkipKey struct {
	script lyricScript
	target string
}

type onDeviceSkipTable struct {
	mu    sync.Mutex
	until map[onDeviceSkipKey]time.Time
}

// skipping:这一组眼下要不要直接跳过端上翻译。
func (t *onDeviceSkipTable) skipping(script lyricScript, target string, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	until, ok := t.until[onDeviceSkipKey{script, target}]
	return ok && now.Before(until)
}

// note 记一次「这一组走不通」,从 now 起 onDeviceSkipFor 之内跳过。
func (t *onDeviceSkipTable) note(script lyricScript, target string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.until[onDeviceSkipKey{script, target}] = now.Add(onDeviceSkipFor)
}

func (t *onDeviceSkipTable) reset() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.until = map[onDeviceSkipKey]time.Time{}
}

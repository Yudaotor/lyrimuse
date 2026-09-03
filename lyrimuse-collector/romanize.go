package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// 罗马音预生成(2026-09-03)。
//
// 在此之前罗马音只有两条路:歌词源自带(`lyrics_roma`),或者 App 在播放时现算
// (LyricsSyncEngine 的客户端兜底)。现算那条有两个实打实的缺陷:
//   ① **导不出去**。lyrics_roma 会被 exportLyricsFiles 写成 `.roma.lrc` 文件,现算的不会
//      —— 用户把歌词文件夹拷到别处、或用别的播放器读,罗马音就丢了。这是唯一真正值得为
//      它动手的理由(省 CPU 不是:App 侧 20Hz 热路径本来就有按行记忆化)。
//   ② 统计口径对不上:实测某台机器 3566 条里只有 114 条带 lyrics_roma(3.2%),而实际
//      显示罗马音的远多于此。
//
// ⚠️ 为什么必须起子进程,而粤拼不用:**差异从来不是"要不要缓存",是"谁算得出来"**。
// 粤拼是纯查表(rime-cantonese 词典 go:embed 进本二进制,见 jyutping.go),Go 自己就算得出。
// 而日文读音**必须**走 CFStringTokenizer 形态分析(不能用 ICU 通用音译:汉字是中日共用的,
// Any-Latin 会一律按普通话读,「火曜日の朝は」→"huǒ yào rìno cháoha"),中文/韩文走 ICU
// applyingTransform(.toLatin) —— 两者都是 Apple 的系统能力,Go 里没有对应物。所以拆成
// lyrics-romanize 这个 Swift 子进程,跟 lyrics-translate / media-control 同一个形态。
//
// ⚠️ helper 内部走的是 `Romanizer.lineReading`,跟 App 播放时的客户端兜底**是同一个函数**。
// 这一点是这条特性能不能成立的前提:预生成的产物必须跟现算逐字一致,否则同一首歌"装了
// 缓存"和"现算"读音不一样 —— 那种不一致不报错,只表现成用户偶尔觉得"某句罗马音怎么变了"。

// 一次调用的上限。本机实测一首 40 行日文歌(最慢的那一档,要走形态分析)在毫秒量级,
// 20 秒是给"歌词特别长 + 机器正忙"留的余量,不是常态预期。超时就当这首没有罗马音,
// 下一轮解析会自然再试一次。
const romanizeHelperTimeout = 20 * time.Second

// onDeviceRomanize 调 lyrics-romanize 把整份逐行 LRC 转成罗马音 LRC。
// 返回空串 = 这首歌本来就没什么可注音的(纯拉丁歌词等),不是错误。
func onDeviceRomanize(lyrics string) (string, error) {
	if lyrics == "" {
		return "", nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	bin := filepath.Join(filepath.Dir(exe), "lyrics-romanize")
	if _, err := os.Stat(bin); err != nil {
		// 没走 build.sh 打包(直接 go build 跑 collector)时找不到 helper —— 静默降级成
		// "这首没有预生成罗马音",App 侧的客户端兜底照常工作,不该因此报错刷日志。
		return "", nil
	}
	payload, err := json.Marshal(struct {
		Lyrics string `json:"lyrics"`
	}{Lyrics: lyrics})
	if err != nil {
		return "", fmt.Errorf("marshal romanize request: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), romanizeHelperTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin)
	cmd.Stdin = bytes.NewReader(payload)
	out, err := cmd.Output()
	// helper 用退出码非 0 表示"没产出",但原因写在 stdout 的 JSON 里 —— 先解析再判错,
	// 别把"这首本来就是拉丁字母"报成执行失败。同 onDeviceTranslate 的处理。
	var res struct {
		OK     bool   `json:"ok"`
		Roma   string `json:"roma"`
		Reason string `json:"reason"`
	}
	if jsonErr := json.Unmarshal(out, &res); jsonErr != nil {
		if err != nil {
			return "", fmt.Errorf("run lyrics-romanize: %w", err)
		}
		return "", fmt.Errorf("parse lyrics-romanize output: %w", jsonErr)
	}
	if !res.OK {
		// no-romanization / empty-input 都是正常结论,不是故障。
		return "", nil
	}
	return res.Roma, nil
}

// maybeGenerateHelperRoma:这一轮没有任何源给出罗马音、粤拼也没接手时,交给 helper 生成
// 一份(日文/韩文/中文)。
//
// ⚠️ 只在 LyricsRoma **原本为空**时补 —— 跟 maybeGenerateJyutpingRoma 同一条规矩:绝不
// 覆盖任何源自己给出的罗马音,哪怕语种判断这次翻车,也不会把已经可用的内容换掉。
//
// ⚠️ **不看用户的语言开关**(RomanizationScripts:日/韩/拼音/粤拼)。那是纯展示层开关
// (App 侧 romanizationAllowed 那道闸在读取 lyrics_roma **之前**),生成不看它 —— 跟粤拼
// 同一个口径。理由:开关是可以随时改的,而生成是一次性的;按开关生成的话,用户打开中文
// 拼音那一刻,存量的几千首中文歌全都得回补一遍,又是一套重扫逻辑。
//
// 文字系统闸(dominantScript)不是可有可无的优化:没有它,每一首纯英文歌都要白起一次子进程。
func (e *enrichEntry) maybeGenerateHelperRoma() {
	if !e.shouldGenerateHelperRoma() {
		return
	}
	roma, err := onDeviceRomanize(e.Lyrics)
	if err != nil || roma == "" {
		return
	}
	e.LyricsRoma = roma
}

// shouldGenerateHelperRoma:该不该为这一条起 helper。
//
// ⚠️ 单独抽出来是为了**能被测到**。判据本身(尤其"已有罗马音就不动"和"粤语该让粤拼先手")
// 是这个功能唯一会造成破坏的地方,而 maybeGenerateHelperRoma 要起子进程 —— 测试二进制旁边
// 没有 lyrics-romanize,直接测那个函数会因为"helper 找不到 → 静默返回"而**恒真通过**,
// 那是一条证明不了任何东西的测试。判据是纯函数,测它才有意义。
func (e *enrichEntry) shouldGenerateHelperRoma() bool {
	if e.Lyrics == "" || e.LyricsRoma != "" {
		return false
	}
	switch dominantScript(e.Lyrics) {
	case scriptHan, scriptKana, scriptHangul:
		return true
	}
	return false
}

// maybeGenerateRoma 是罗马音兜底的**唯一入口**,顺序固定:
//   ① 粤拼(纯查表,本进程算得出,只认粤语);
//   ② helper(日/韩/中,要 Apple 系统能力)。
//
// ⚠️ 顺序不能反。粤拼带数字声调、是专门为粤语做的词典查表,质量高于 helper 那条通用
// ICU 音译(粤语汉字走 .toLatin 会出普通话拼音,完全不对)。两个函数都只在 LyricsRoma
// 为空时才动手,所以①先跑就等于"粤语优先用粤拼"。
//
// 三个调用点(retryLyricsUpgrade / rescoreLyrics / resolveTrackEnrichment)统一走这个
// 包装,别再各自单独调①—— 那样第二步会被漏掉,而且漏掉是静默的。
func (e *enrichEntry) maybeGenerateRoma() {
	e.maybeGenerateJyutpingRoma()
	e.maybeGenerateHelperRoma()
}

package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

// 2026-09-02 接回酷狗 KRC `[language:<base64>]` 内嵌的译文 / 罗马音两轨。样本按当天直连接口
// 看到的真实结构仿写(Lemon / Ditto 的形状,正文换成占位文字),钉住的是解析与对齐规则。

func krcLanguageB64(t *testing.T, content []map[string]any) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"content": content, "version": 1})
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(raw)
}

const krcLangSampleBody = "[ti:示例]\n" +
	"[ar:示例歌手]\n" +
	"[0,1000]<0,500,0>示例<500,500,0>曲目\n" +
	"[1134,1246]<0,400,0>夢<400,846,0>ならば\n" +
	"[2380,4002]<0,2000,0>どれほど<2000,2002,0>よかったでしょう\n" +
	"[6382,5527]<0,5527,0>未だにあなたのことを夢にみる\n"

func TestSplitKRCLanguageLineStripsFromBody(t *testing.T) {
	krc := "[ti:示例]\r\n[language:QUJD]\r\n[0,1000]<0,500,0>示例<500,500,0>曲目\r\n"
	b64, rest := splitKRCLanguageLine(krc)
	if b64 != "QUJD" {
		t.Fatalf("base64 正文摘错: %q", b64)
	}
	if strings.Contains(rest, "language") || !strings.Contains(rest, "[0,1000]") || !strings.Contains(rest, "[ti:示例]") {
		t.Fatalf("剩余正文不对: %q", rest)
	}
	if strings.Contains(krcToYRC(rest), "language") {
		t.Fatal("YRC 里不该再有 language 行")
	}
	if b, r := splitKRCLanguageLine("[0,10]<0,10,0>a"); b != "" || r != "[0,10]<0,10,0>a" {
		t.Fatalf("没有 language 行时应原样返回: %q / %q", b, r)
	}
}

// 两轨按行序号对齐 KRC 计时行的行始;空片段(署名行)与 `//` 跳过;罗马音片段自带空格、多余
// 空白折成一个。
func TestKRCLanguageTracksAlignByLineIndex(t *testing.T) {
	b64 := krcLanguageB64(t, []map[string]any{
		{"type": 1, "language": 0, "lyricContent": [][]string{{""}, {"要是这是场梦"}, {"该有多好"}, {"至今仍会梦见你"}}},
		{"type": 0, "language": 0, "lyricContent": [][]string{{"//"}, {"yu ", "me ", "na ", "ra ", "ba"}, {"do ", "re ", "ho ", "do  ", "yo"}, {"i ", "ma ", "da ", "ni"}}},
	})
	tr, roma := krcLanguageTracks(b64, krcLangSampleBody)
	wantTr := "[00:01.134]要是这是场梦\n[00:02.380]该有多好\n[00:06.382]至今仍会梦见你"
	if tr != wantTr {
		t.Fatalf("译文轨不对\n实际:\n%s\n期望:\n%s", tr, wantTr)
	}
	wantRoma := "[00:01.134]yu me na ra ba\n[00:02.380]do re ho do yo\n[00:06.382]i ma da ni"
	if roma != wantRoma {
		t.Fatalf("罗马音轨不对\n实际:\n%s\n期望:\n%s", roma, wantRoma)
	}
}

// 行数与 KRC 计时行数不等 → 整轨放弃(对不齐宁可整体不要)。
func TestKRCLanguageTracksRejectLineCountMismatch(t *testing.T) {
	b64 := krcLanguageB64(t, []map[string]any{
		{"type": 1, "lyricContent": [][]string{{"只有"}, {"三行"}, {"译文"}}},
	})
	if tr, roma := krcLanguageTracks(b64, krcLangSampleBody); tr != "" || roma != "" {
		t.Fatalf("行数错配应放弃,实际 tr=%q roma=%q", tr, roma)
	}
}

// 韩文歌的 type 0 轨是中文谐音(实测 Ditto:「马列做 say it back」),不是罗马音——按汉字占比挡掉;
// 译文轨不受影响。
func TestKRCLanguageTracksDropHomophoneRomaTrack(t *testing.T) {
	b64 := krcLanguageB64(t, []map[string]any{
		{"type": 0, "lyricContent": [][]string{{""}, {"马列做 ", "say ", "it ", "back"}, {"啊亲们 ", "挠木 ", "摸咯"}, {"呼走 ", "扣剖撩搜"}}},
		{"type": 1, "lyricContent": [][]string{{""}, {"总是模棱两可"}, {"我有点喜欢你"}, {"不要打谜语"}}},
	})
	tr, roma := krcLanguageTracks(b64, krcLangSampleBody)
	if roma != "" {
		t.Fatalf("谐音轨应被挡掉,实际 %q", roma)
	}
	if !strings.Contains(tr, "[00:01.134]总是模棱两可") {
		t.Fatalf("译文轨应保留,实际 %q", tr)
	}
}

// 坏 base64 / 坏 JSON / 空串都安静地返回空,不影响逐字主路径。
func TestKRCLanguageTracksTolerateGarbage(t *testing.T) {
	for _, b64 := range []string{"", "not base64!!", base64.StdEncoding.EncodeToString([]byte("{not json"))} {
		if tr, roma := krcLanguageTracks(b64, krcLangSampleBody); tr != "" || roma != "" {
			t.Fatalf("输入 %q 应返回空,实际 tr=%q roma=%q", b64, tr, roma)
		}
	}
}

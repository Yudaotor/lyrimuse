package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// useFakeGoogle 把 Google 那一家指向假服务器,并清掉冷却状态;结束时恢复成 TestMain 设的
// "跳过"。冷却是包级状态,不清的话前一个用例的 429 会让后一个用例直接跳过 Google。
func useFakeGoogle(t *testing.T, handler http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(handler)
	prev := googleTranslateEndpoint
	googleTranslateEndpoint = srv.URL
	googleTranslateMu.Lock()
	googleTranslateCoolUntil = time.Time{}
	googleTranslateMu.Unlock()
	t.Cleanup(func() {
		srv.Close()
		googleTranslateEndpoint = prev
		googleTranslateMu.Lock()
		googleTranslateCoolUntil = time.Time{}
		googleTranslateMu.Unlock()
	})
}

// googleReply 按真实返回形状拼一个响应:故意把译文切成两段,覆盖"要把所有段拼起来"那条。
func googleReply(t *testing.T, translated []string) string {
	t.Helper()
	text := strings.Join(translated, "\n")
	cut := strings.Index(text, "\n")
	if cut < 0 {
		cut = len(text)
	} else {
		cut++ // 换行留在第一段末尾,跟真实返回一致
	}
	body, err := json.Marshal([]any{
		[]any{
			[]any{text[:cut], "src-1", nil, nil, 3},
			[]any{text[cut:], "src-2", nil, nil, 3},
		},
		nil, "ja",
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func TestGoogleTranslateUsedBeforeMyMemory(t *testing.T) {
	var gotMethod, gotClient, gotTarget, gotQ string
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotClient = r.URL.Query().Get("client")
		gotTarget = r.URL.Query().Get("tl")
		_ = r.ParseForm()
		gotQ = r.PostForm.Get("q")
		var out []string
		for _, l := range strings.Split(gotQ, "\n") {
			out = append(out, "译:"+l)
		}
		fmt.Fprint(w, googleReply(t, out))
	})
	var myMemoryHits atomic.Int32
	mm := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		myMemoryHits.Add(1)
		fmt.Fprint(w, `{"responseData":{"translatedText":"x\ny\nz"},"responseStatus":200}`)
	})

	lrc := "[00:01.00]one\n[00:02.00]two\n[00:03.00]three"
	res, err := machineTranslateLRCWithBase(context.Background(), mm.Client(), mm.URL, lrc, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	want := "[00:01.00]译:one\n[00:02.00]译:two\n[00:03.00]译:three"
	if res.lrc != want {
		t.Errorf("译文不对:\n got %q\nwant %q", res.lrc, want)
	}
	if n := myMemoryHits.Load(); n != 0 {
		t.Errorf("Google 已经翻出来了,不该再请求 MyMemory,实际 %d 次", n)
	}
	if gotMethod != http.MethodPost || gotClient != "dict-chrome-ex" || gotTarget != "zh-CN" {
		t.Errorf("请求形状不对: method=%s client=%s tl=%s", gotMethod, gotClient, gotTarget)
	}
	if gotQ != "one\ntwo\nthree" {
		t.Errorf("正文应放在 POST 表单里、按行拼接,实际 %q", gotQ)
	}
}

// 服务层失败(这里是 429,gtx 那个 client 就是这么被封的)要退回 MyMemory,并且冷却这一家:
// 下一首歌不该再撞一次同一堵墙。
func TestGoogleTranslateServiceFailureFallsBackAndCoolsDown(t *testing.T) {
	var googleHits atomic.Int32
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		googleHits.Add(1)
		w.WriteHeader(http.StatusTooManyRequests)
	})
	var myMemoryHits atomic.Int32
	mm := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		myMemoryHits.Add(1)
		fmt.Fprint(w, `{"responseData":{"translatedText":"一\n二"},"responseStatus":200}`)
	})

	lrc := "[00:01.00]one\n[00:02.00]two"
	for i := 0; i < 2; i++ {
		res, err := machineTranslateLRCWithBase(context.Background(), mm.Client(), mm.URL, lrc, "zh-CN", "", "")
		if err != nil {
			t.Fatal(err)
		}
		if res.lrc != "[00:01.00]一\n[00:02.00]二" {
			t.Fatalf("第 %d 次应由 MyMemory 兜住,实际 %q", i+1, res.lrc)
		}
	}
	if n := googleHits.Load(); n != 1 {
		t.Errorf("429 之后应进入冷却、第二首不再请求 Google,实际请求了 %d 次", n)
	}
	if n := myMemoryHits.Load(); n != 2 {
		t.Errorf("两首都应由 MyMemory 翻,实际 %d 次", n)
	}
}

// 服务正常、只是这批内容没翻出可用结果(这里是行数对不上)—— 继续试 MyMemory,但不冷却:
// 那不是服务挂了。
func TestGoogleTranslateContentMissFallsThroughWithoutCooldown(t *testing.T) {
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, googleReply(t, []string{"只回一行"}))
	})
	var myMemoryHits atomic.Int32
	mm := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		myMemoryHits.Add(1)
		fmt.Fprint(w, `{"responseData":{"translatedText":"一\n二"},"responseStatus":200}`)
	})

	lrc := "[00:01.00]one\n[00:02.00]two"
	res, err := machineTranslateLRCWithBase(context.Background(), mm.Client(), mm.URL, lrc, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if res.lrc != "[00:01.00]一\n[00:02.00]二" {
		t.Errorf("Google 行数对不上时应退到 MyMemory,实际 %q", res.lrc)
	}
	if myMemoryHits.Load() != 1 {
		t.Errorf("MyMemory 应被请求一次,实际 %d", myMemoryHits.Load())
	}
	if googleTranslateCooling(time.Now()) {
		t.Error("内容没翻出来不该让 Google 进入冷却")
	}
}

func TestParseGoogleTranslateResponse(t *testing.T) {
	got, err := parseGoogleTranslateResponse([]byte(
		`[[["因为我喜欢你\n","君のことが好きだから\n",null,null,3],["我的青春","my youth",null,null,3]],null,"ja"]`))
	if err != nil || got != "因为我喜欢你\n我的青春" {
		t.Errorf("多段应按顺序拼接: got %q err %v", got, err)
	}
	if got, err := parseGoogleTranslateResponse([]byte(`[null,null,"en"]`)); err != nil || got != "" {
		t.Errorf("没有译文时应返回空串而不是报错: got %q err %v", got, err)
	}
	if _, err := parseGoogleTranslateResponse([]byte(`<html>Sorry...</html>`)); err == nil {
		t.Error("反爬页之类的非 JSON 返回应报错(触发冷却)")
	}
}

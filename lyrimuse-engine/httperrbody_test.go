package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"unicode/utf8"
)

// ListenBrainz 宕机时回的那种带样式的 502 页(截自真实日志,前 512 字节)。
const lbBadGatewayPage = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n" +
	"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>502 Bad Gateway</title>\n<style>\n" +
	"  body {\n    font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif;\n    max-width: 600px;\n"

func TestHTTPErrorBody(t *testing.T) {
	long := strings.Repeat("错误", 200)
	for _, c := range []struct {
		name, contentType, body, want string
	}{
		{"HTML 错误页只取标题", "text/html", lbBadGatewayPage, "502 Bad Gateway"},
		{"没带 Content-Type 也认得出 HTML", "", lbBadGatewayPage, "502 Bad Gateway"},
		{"标题里的实体和换行", "text/html; charset=utf-8", "<html><title>\n  Service &amp; Gateway\n </title></html>", "Service & Gateway"},
		{"没有标题的 HTML", "text/html", "<html><body><h1>Oops</h1></body></html>", "an HTML page"},
		{"JSON 错误原样压成一行", "application/json", "{\n  \"code\": 400,\n  \"error\": \"Invalid listen\"\n}", "{ \"code\": 400, \"error\": \"Invalid listen\" }"},
		{"空响应体", "", "  \n ", ""},
	} {
		if got := httpErrorBody(c.contentType, []byte(c.body)); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
	got := httpErrorBody("text/plain", []byte(long))
	if len(got) > httpErrorBodyMax+len("…") || !strings.HasSuffix(got, "…") || !utf8.ValidString(got) {
		t.Errorf("长响应体截到 %d 字节以内、不截断字符: len=%d %q", httpErrorBodyMax, len(got), got[len(got)-10:])
	}
}

// ListenBrainz 回 HTML 错误页时,错误信息(进日志的那句)只带状态码和页面标题。
func TestLBSubmitErrorOmitsHTMLPage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(lbBadGatewayPage))
	}))
	defer srv.Close()
	c := &lbClient{root: srv.URL, token: "t", hc: srv.Client()}
	status, err := c.submitOnce(context.Background(), []byte(`{}`), playingNowTimeout)
	if status != http.StatusBadGateway || err == nil || err.Error() != "status 502: 502 Bad Gateway" {
		t.Fatalf("status=%d err=%v", status, err)
	}
}

// ListenBrainz 提交先直连、不通再走系统代理:client 用的是 proxyFallbackTransport,main.go 里那个 lbClient 用的就是它。
func TestLBSubmitFallsBackToSystemProxy(t *testing.T) {
	if _, ok := lbHTTPClient().Transport.(*proxyFallbackTransport); !ok {
		t.Fatalf("lbHTTPClient 的 Transport 是 %T", lbHTTPClient().Transport)
	}
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "lb := &lbClient{root: cfg.APIRoot, token: cfg.Token, hc: lbHTTPClient(),") {
		t.Error("main.go 里的 lbClient 没用 lbHTTPClient()")
	}
}

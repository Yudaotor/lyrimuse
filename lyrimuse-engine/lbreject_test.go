package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

// 只有 400 / 413 算「这条内容不收」;404 这类网关路由问题当暂时失败,不带 errListenRejected(12 章决策 70)。
func TestLBContentRejectedOnlyFor400And413(t *testing.T) {
	for status, rejected := range map[int]bool{400: true, 413: true, 404: false, 405: false, 410: false, 500: false, 503: false} {
		if lbContentRejected(status) != rejected {
			t.Errorf("status %d: rejected=%v, want %v", status, !rejected, rejected)
		}
	}
	for status, rejected := range map[int]bool{http.StatusNotFound: false, http.StatusBadRequest: true} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) }))
		c := &lbClient{root: srv.URL, token: "t", hc: srv.Client()}
		err := c.submit(context.Background(), "playing_now", 0, lbTrackMeta{ArtistName: "A", TrackName: "T", AdditionalInfo: map[string]any{}})
		srv.Close()
		if err == nil || errors.Is(err, errListenRejected) != rejected {
			t.Errorf("submit 遇到 %d: err=%v, 算拒收 %v", status, err, rejected)
		}
	}
}

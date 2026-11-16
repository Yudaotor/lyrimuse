package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

// ---- 歌词源 200 应答体的共用入口 ----
//
// 歌词源拿到 200 之后读应答体一律走这里,不直接 json.NewDecoder(resp.Body).Decode:应答体为空(只有空白也算)是网关
// 整体拒收,不是「没搜到」(没搜到照样回一份带内容的 JSON),直接解码只会得到一次 io.EOF 失败,出站闸看到的是 200、
// 接口熔断永远不跳闸,每首歌照问。这里按这个接口被拒记一次(reportEndpointRejected),连着被拒由 hostguard 熔断、
// 逐档停用、到期放试探。见 09 章决策 375、376。源码契约 TestLyricSourceBodiesUseSharedReader 守着这条。
//
// 两种用法:
//   - decodeLyricSourceJSON:应答体里不另认拒绝的接口。解得动就记一次 reportEndpointAccepted,清掉拒绝计数。
//   - decodeJudgedLyricSourceJSON / readLyricSourceBody:调用方还要从应答体里认拒绝码,认完自己记
//     reportEndpointAccepted / reportEndpointRejected。这里不能先记 Accepted:同一次应答先清零再加一,拒绝计数永远攒不满。

// errLyricSourceEmptyAnswer:接口回了 200,应答体却是空的。
var errLyricSourceEmptyAnswer = errors.New("answered 200 with an empty body")

// readLyricSourceBody 读完 200 应答的应答体(最多 limit 字节)。空的按 req 这个接口被拒记一次,返回 errLyricSourceEmptyAnswer。
// 非空时不记好坏,由调用方认完形状再记。
func readLyricSourceBody(req *http.Request, resp *http.Response, limit int64) ([]byte, error) {
	raw, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	if err != nil {
		return nil, err
	}
	if err := rejectEmptyLyricSourceBody(req, raw); err != nil {
		return nil, err
	}
	return raw, nil
}

// rejectEmptyLyricSourceBody:已经读出来的 200 应答体 raw 为空时按 req 这个接口被拒记一次,返回 errLyricSourceEmptyAnswer。
// 给要先读整段、看过状态码再判的调用方(Deezer GraphQL 那样 401 要重换票的)。
func rejectEmptyLyricSourceBody(req *http.Request, raw []byte) error {
	if len(bytes.TrimSpace(raw)) > 0 {
		return nil
	}
	reportEndpointRejected(req.URL)
	return errLyricSourceEmptyAnswer
}

// decodeJudgedLyricSourceJSON:readLyricSourceBody 加解出第一个 JSON 值(口径同 json.Decoder,后面跟着的内容不管)。不记 Accepted。
func decodeJudgedLyricSourceJSON(req *http.Request, resp *http.Response, limit int64, out any) error {
	raw, err := readLyricSourceBody(req, resp, limit)
	if err != nil {
		return err
	}
	return json.NewDecoder(bytes.NewReader(raw)).Decode(out)
}

// decodeLyricSourceJSON:decodeJudgedLyricSourceJSON,解得动就记一次 reportEndpointAccepted。
func decodeLyricSourceJSON(req *http.Request, resp *http.Response, limit int64, out any) error {
	if err := decodeJudgedLyricSourceJSON(req, resp, limit, out); err != nil {
		return err
	}
	reportEndpointAccepted(req.URL)
	return nil
}

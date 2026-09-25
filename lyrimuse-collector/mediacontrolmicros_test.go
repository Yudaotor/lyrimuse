package main

import (
	"encoding/json"
	"testing"
	"time"
)

// 样本取自同一时刻的两次实测输出:整秒 timestamp 与 timestampEpochMicros = 1790180829813474 只差被截掉的 .813474。
// 带 --micros 时四个时间键被替换成微秒版,applyMicros 换算回原字段。
func TestApplyMicrosConvertsReplacedKeys(t *testing.T) {
	var raw mediaControlRawState
	in := `{"title":"x","durationMicros":247152993,"elapsedTimeMicros":143288238,"elapsedTimeNowMicros":150000000,"timestampEpochMicros":1790180829813474}`
	if err := json.Unmarshal([]byte(in), &raw); err != nil {
		t.Fatal(err)
	}
	raw.applyMicros()
	if raw.Duration != 247.152993 || raw.ElapsedTime != 143.288238 || raw.ElapsedTimeNow != 150 {
		t.Errorf("数值换算不对: duration=%v elapsed=%v elapsedNow=%v", raw.Duration, raw.ElapsedTime, raw.ElapsedTimeNow)
	}
	if raw.Timestamp != "2026-09-23T16:27:09.813474Z" {
		t.Errorf("时间戳应写成固定 6 位小数的 RFC3339,实际 %q", raw.Timestamp)
	}
}

func TestApplyMicrosLeavesPlainOutputAlone(t *testing.T) {
	var raw mediaControlRawState
	in := `{"duration":247.152993,"elapsedTime":143.288238,"elapsedTimeNow":150,"timestamp":"2026-09-23T16:27:09Z"}`
	if err := json.Unmarshal([]byte(in), &raw); err != nil {
		t.Fatal(err)
	}
	raw.applyMicros()
	if raw.Timestamp != "2026-09-23T16:27:09Z" || raw.ElapsedTime != 143.288238 {
		t.Errorf("不带 --micros 的输出不该被改动: %+v", raw)
	}
}

// 微秒恰好落在整秒上时也必须带小数点,否则 mediaControlAnchorInstant 会把它当旧格式再补半秒。
func TestApplyMicrosKeepsFractionOnWholeSecond(t *testing.T) {
	v := int64(1790180829000000)
	raw := mediaControlRawState{TimestampEpochMicros: &v}
	raw.applyMicros()
	if raw.Timestamp != "2026-09-23T16:27:09.000000Z" {
		t.Errorf("整秒的微秒值也要写出 .000000,实际 %q", raw.Timestamp)
	}
	got, ok := mediaControlAnchorInstant(raw.Timestamp)
	if !ok || !got.Equal(time.UnixMicro(v)) {
		t.Errorf("整秒的精确值不该再补半秒: %v", got)
	}
}

func TestMediaControlAnchorInstant(t *testing.T) {
	precise, ok := mediaControlAnchorInstant("2026-09-23T16:27:09.813474Z")
	if !ok || !precise.Equal(time.UnixMicro(1790180829813474)) {
		t.Errorf("精确时间戳应原样用,实际 %v", precise)
	}
	floored, ok := mediaControlAnchorInstant("2026-09-23T16:27:09Z")
	want := time.Unix(1790180829, 0).Add(500 * time.Millisecond)
	if !ok || !floored.Equal(want) {
		t.Errorf("整秒时间戳应取中点 ts+0.5,实际 %v", floored)
	}
	if _, ok := mediaControlAnchorInstant(""); ok {
		t.Error("空串应返回 false")
	}
}

// rate 缺失分支(Spotify 暂停后恢复的形态):精确锚点直接外推,不再有 0.5s 的中点偏差。
func TestPlayingPositionSecsPreciseAnchor(t *testing.T) {
	anchor := time.UnixMicro(1790180829813474)
	got := playingPositionSecs(143.288238, 143.288238, 0, "2026-09-23T16:27:09.813474Z", anchor.Add(10*time.Second))
	if d := got - 153.288238; d > 1e-6 || d < -1e-6 {
		t.Errorf("精确锚点外推 10s 应得 153.288238,实际 %v", got)
	}
}

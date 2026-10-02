package main

import (
	"context"
	"log"
	"strings"
	"time"
)

// swapTranslationTimeout 换正文之前先机翻新正文最多等多久。超时就照常换,换上之后由
// translateAfterLyricsSwapLocked 接着补。
var swapTranslationTimeout = 30 * time.Second

// swapTranslation 播放中自动换正文时预先翻好的新译文(见 prepareSwapTranslation)。零值 = 没有。
type swapTranslation struct {
	lyrics string // 这份译文对着的正文
	lrc    string
	target string
}

// prepareSwapTranslation:正在播的这首这一轮要换正文(willSwap 按锁内的条目判),现在这份带着能用的译文、
// 新胜者却没有时,先把新正文机翻好,让正文和译文同一次换上 —— 不然从换正文到机翻落地,译文是空的
// (见 10 章决策 29)。机翻关着、没在播、现在这份本来就没有能用的译文、新胜者自带能用的、新正文没有
// 要翻的行,都不翻。调用方不持有 enrichMu。翻不成返回零值,换正文照常进行。
func prepareSwapTranslation(ctx context.Context, key, artist, title string, picked *scoredLyricCandidateResult,
	willSwap func(enrichEntry) bool) swapTranslation {
	if picked == nil || picked.Lyrics == "" || !features().LyricsMachineTranslation {
		return swapTranslation{}
	}
	if cur := enrichPlayingKey.Load(); cur == nil || *cur != key {
		return swapTranslation{}
	}
	target := myMemoryLangCode(features().LyricsTranslationLanguage)
	if target == "" {
		return swapTranslation{}
	}
	enrichMu.Lock()
	e, ok := enrichCache[key]
	needed := ok && translationUsable(e, target) && willSwap(e)
	enrichMu.Unlock()
	if !needed {
		return swapTranslation{}
	}
	if translationUsable(enrichEntry{LyricsTr: picked.LyricsTr, LyricsTrLang: picked.LyricsTrLang}, target) {
		return swapTranslation{}
	}
	if !hasTranslatableLines(picked.Lyrics, target, artist, title) {
		return swapTranslation{}
	}
	tctx, cancel := context.WithTimeout(ctx, swapTranslationTimeout)
	defer cancel()
	started := time.Now()
	res, err := machineTranslateLRC(tctx, translateClient, picked.Lyrics, target, artist, title)
	took := time.Since(started).Seconds()
	if err != nil || res.lrc == "" {
		log.Printf("translate: %s could not translate the new lyrics before swapping them in (%.1fs), swapping without a translation", key, took)
		return swapTranslation{}
	}
	log.Printf("translate: %s translated the new lyrics before swapping them in (%d lines, engines: %s, %.1fs)",
		key, strings.Count(res.lrc, "\n")+1, res.engines, took)
	return swapTranslation{lyrics: picked.Lyrics, lrc: res.lrc, target: target}
}

// applyLocked 把预先翻好的译文挂到刚换上的正文上;正文对不上(锁外到锁内之间又被换过)或这一刻已经有能用的
// 译文时不挂。写的字段跟 backfillTranslation 翻成时一致。调用方持有 enrichMu。
func (s swapTranslation) applyLocked(e *enrichEntry) {
	if s.lrc == "" || e.Lyrics != s.lyrics || translationUsable(*e, s.target) {
		return
	}
	e.LyricsTr, e.LyricsTrSource, e.LyricsTrLang = s.lrc, lyricsTrSourceMachine, s.target
	e.TranslationLang = s.target
	e.TranslationTS, e.TranslationRetryCount = 0, 0
}

package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// 借鉴清单 V2 端到端:两两 Jaccard 算出来的**互证名单**要一路走到序列化后的 JSON 里。
// 不联网、不碰用户缓存 —— 用真实的 rankLyricSourceResults 跑一轮本地候选。
func TestConsensusPeersReachDecisionJSON(t *testing.T) {
	// 两份内容一致(netease/qq)、一份完全不同(kugou)。三份都过 isTimedLRC 的三行门槛,
	// 正文都够 lyricConsensusMinBodyRunes。
	same := "[00:01.00]we were both young when i first saw you\n" +
		"[00:06.00]i close my eyes and the flashback starts\n" +
		"[00:11.00]im standing there on a balcony in summer air\n" +
		"[00:16.00]see the lights see the party the ball gowns\n"
	diff := "[00:01.00]completely different words entirely here\n" +
		"[00:06.00]nothing at all shared with the other two\n" +
		"[00:11.00]another unrelated closing line for this one\n" +
		"[00:16.00]and one more line that matches nobody else\n"
	// 刻意避开 netease/amll:那两路的正文分别走 ne / amll 字段,不是 lyr。
	raw := map[string]lyricSourceResult{
		"qq":     {source: "qq", lyr: same},
		"lrclib": {source: "lrclib", lyr: same},
		"kugou":  {source: "kugou", lyr: diff},
	}
	scored := rankLyricSourceResults("someone", "song", "", 0, raw)

	bySource := map[string]scoredLyricCandidateResult{}
	for _, c := range scored {
		bySource[c.Source] = c
	}
	// netease 与 qq 必须互相点名;kugou 谁也不认。
	for _, tc := range []struct{ src, peer string }{{"qq", "lrclib"}, {"lrclib", "qq"}} {
		got := bySource[tc.src].ConsensusPeers
		if len(got) != 1 || got[0] != tc.peer {
			t.Errorf("%s 的 ConsensusPeers = %v, want [%s] —— 名单没从 contentConsensusPeers 传到候选上",
				tc.src, got, tc.peer)
		}
	}
	if got := bySource["kugou"].ConsensusPeers; len(got) != 0 {
		t.Errorf("kugou 正文跟谁都不一样,ConsensusPeers 应为空,实际 %v", got)
	}
	// 判据没变:len(名单) 就是原来那个计数,+250/+150 照旧。
	qqTerms := map[string]int{}
	for _, tm := range bySource["qq"].ScoreTerms {
		qqTerms[tm.Kind] = tm.Points
	}
	if qqTerms[scoreTermConsensus] != 150 {
		t.Errorf("qq 的 consensus 分 = %d, want 150(1 家印证)—— 换成名单不该改变判据",
			qqTerms[scoreTermConsensus])
	}

	// 一路到 JSON。App 侧 LyricsResolutionDecision.Candidate.consensusPeers 走
	// .convertFromSnakeCase,对应的键名必须是 consensus_peers。
	win := bySource["qq"]
	d := buildLyricsDecision(lyricsDecisionPathFirstResolve, "someone", "song", "", 0, scored, &win, true)
	blob, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(blob), `"consensus_peers":["lrclib"]`) {
		t.Errorf("序列化后的存档里找不到 consensus_peers:\n%s", blob)
	}
}

// 借鉴清单 V1 端到端:查询词记录 → 存档 → JSON,键名与嵌套结构都要对得上 App 侧解码。
func TestQueriesTriedReachDecisionJSON(t *testing.T) {
	ctx, log := withLyricQueryLog(context.Background())

	// ① 首轮:没标来路、没有源名单。
	log.record("音樂頑童", "Musiq Soulchild - Buddy", lyricQueryReasonFrom(ctx), sortedLyricSourceOnly(ctx))
	// ② 拆分重入。
	splitCtx := withLyricQueryReason(ctx, lyricQueryReasonTitleSplit)
	log.record("Musiq Soulchild", "Buddy", lyricQueryReasonFrom(splitCtx), sortedLyricSourceOnly(splitCtx))
	// ③ 别名轮 + 定向重查:源名单必须**按 lyricSourceNames 的规范顺序**落盘,不能是 map 随机序。
	aliasCtx := withLyricQueryReason(withLyricSourceOnly(ctx, []string{"musixmatch", "qq", "kugou"}),
		lyricQueryReasonAliasMissing)
	log.record("JW", "NOT YOUR FAULT", lyricQueryReasonFrom(aliasCtx), sortedLyricSourceOnly(aliasCtx))

	got := log.queries()
	if len(got) != 3 {
		t.Fatalf("记了 %d 组查询词, want 3: %+v", len(got), got)
	}
	if got[0].Reason != "" || got[0].Artist != "音樂頑童" || len(got[0].Sources) != 0 {
		t.Errorf("首轮那一组不对: %+v", got[0])
	}
	if got[1].Reason != lyricQueryReasonTitleSplit || got[1].Artist != "Musiq Soulchild" {
		t.Errorf("拆分那一组不对: %+v", got[1])
	}
	// 定序:qq → kugou → musixmatch(lyricSourceNames 的顺序),不是字典序、更不是 map 序。
	if want := []string{"qq", "kugou", "musixmatch"}; strings.Join(got[2].Sources, ",") != strings.Join(want, ",") {
		t.Errorf("别名轮的源名单 = %v, want %v —— 必须按 lyricSourceNames 定序,否则同一轮解析每次序列化出不同 JSON",
			got[2].Sources, want)
	}

	d := buildLyricsDecision(lyricsDecisionPathFirstResolve, "音樂頑童", "Musiq Soulchild - Buddy", "", 0, nil, nil, false)
	d.QueriesTried = got
	blob, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	s := string(blob)
	for _, needle := range []string{
		`"queries_tried":[`,
		`{"artist":"音樂頑童","title":"Musiq Soulchild - Buddy"}`, // 首轮:reason/sources 都 omitempty
		`"reason":"title-split"`,
		`"reason":"alias-missing","sources":["qq","kugou","musixmatch"]`,
	} {
		if !strings.Contains(s, needle) {
			t.Errorf("序列化后的存档里找不到 %s:\n%s", needle, s)
		}
	}
}

// 相邻去重:同一组词 + 同一来路 + 同一源名单连着记两遍是噪音(变体轮的"首歌手"可能跟
// retryArtistIdentities 的第一个别名撞上,dedupeArtistIdentities 管不到跨轮重复)。
func TestQueryLogDedupesAdjacentDuplicates(t *testing.T) {
	_, log := withLyricQueryLog(context.Background())
	log.record("A", "T", lyricQueryReasonPrimaryVar, nil)
	log.record("A", "T", lyricQueryReasonPrimaryVar, nil)
	log.record("B", "T", lyricQueryReasonPrimaryVar, nil)
	log.record("A", "T", lyricQueryReasonPrimaryVar, nil) // 不相邻,保留
	if got := log.queries(); len(got) != 3 {
		t.Errorf("相邻去重后应剩 3 组,实际 %d: %+v", len(got), got)
	}
	// 上限护栏。
	_, capped := withLyricQueryLog(context.Background())
	for i := 0; i < lyricQueryLogMax+10; i++ {
		capped.record("A", string(rune('a'+i%26))+string(rune('0'+i/26)), lyricQueryReasonAliasRescue, nil)
	}
	if got := capped.queries(); len(got) != lyricQueryLogMax {
		t.Errorf("上限没生效: %d 组, want %d", len(got), lyricQueryLogMax)
	}
	// 没挂收集器时是空操作,不 panic。
	var nilLog *lyricQueryLog
	nilLog.record("A", "T", "", nil)
	if got := nilLog.queries(); got != nil {
		t.Errorf("nil 收集器应返回 nil,实际 %v", got)
	}
	if got := lyricQueryLogFrom(context.Background()); got != nil {
		t.Errorf("ctx 上没挂时应返回 nil,实际 %v", got)
	}
}

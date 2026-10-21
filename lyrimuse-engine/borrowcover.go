package main

import "strings"

// applyBorrowedCovers 给自己没有封面的候选借一张:同一批里排在最前、ISRC 跟它相同(coverDonorFits)、自带封面的那条。
// 每轮先清掉上一轮借的,合并轮次后重算。只填 BorrowedCoverURL / BorrowedCoverFrom,CoverURL 不动。见 11 章决策 140。
func applyBorrowedCovers(results []scoredLyricCandidateResult) {
	for i := range results {
		results[i].BorrowedCoverURL, results[i].BorrowedCoverFrom = "", ""
	}
	for i := range results {
		r := &results[i]
		if r.CoverURL != "" || r.Lyrics == "" {
			continue
		}
		for j := range results {
			d := &results[j]
			if j == i || d.CoverURL == "" || !coverDonorFits(*r, *d) {
				continue
			}
			r.BorrowedCoverURL, r.BorrowedCoverFrom = d.CoverURL, d.Source
			break
		}
	}
}

// coverDonorFits:d 跟 r 是不是同一条录音 —— 两边都报了 ISRC 且相同。歌名、歌手、专辑、时长都对得上也不算,不借。纯函数。
func coverDonorFits(r, d scoredLyricCandidateResult) bool {
	return r.ISRC != "" && d.ISRC != "" && strings.EqualFold(r.ISRC, d.ISRC)
}

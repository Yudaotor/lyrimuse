package main

// candidateSlots 按来源收排序用的候选,一个来源一格。吐出来的先后是同分决胜序(登记表的 tieOrder),跟各来源那段装配
// 写在哪、先装谁没有关系:排序是稳定的,同分的候选谁在前谁赢,这个先后只由这里定。合并几轮结果的
// mergeLyricCandidateRounds 按同一份 tieOrder 重建顺序。
type candidateSlots map[string]lyricCandidate

func (s candidateSlots) put(c lyricCandidate) { s[c.source] = c }

// inTieOrder:收到的候选按同分决胜序。没登记的源名不在决胜序里,不吐。
func (s candidateSlots) inTieOrder() []lyricCandidate {
	var out []lyricCandidate
	for _, name := range lyricProviders().tieOrder {
		if c, ok := s[name]; ok {
			out = append(out, c)
		}
	}
	return out
}

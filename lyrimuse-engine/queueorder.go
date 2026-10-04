package main

// 从换歌行为推断「顺序 / 随机」,以及随机时交出去预解析的那一批。QQ 与酷狗共用。
//
// 两家都没有可信的播放模式可读:QQ 的模式只存在加密的 MMKV 里;酷狗的 KugouConfigPlist.plist 有个
// playMode,但实测随机播放时它照样是 0(见 kugouqueue.go 头注)。所以只看行为:新的一首正好是上一首的
// 下一位 = 顺序;跳到别处 = 随机。列表换了就清空重新攒证据;还没有证据时按顺序处理。

// 随机播放时下一首是列表里的哪一首猜不出来 —— 实测(QQ)14 首的列表第 10 次就抽到了放过的歌,
// 放完 16 首还有一首一次没轮到,不是「打乱一轮再重来」。能确定的只有「一定出自这份列表」,所以:
//   - 列表不超过 queueShuffleWholeListMax 首:整份交出去预解析(已解析的由 queueUpcomingEnrich 跳过);
//   - 更大的列表:每换一首从当前位置往后(到末尾接回开头)挑 queueShuffleBatch 首还没解析过的,
//     覆盖面随播放逐步扩大,一次换歌最多多解析这么几首。
const (
	queueShuffleWholeListMax = 30
	queueShuffleBatch        = 5
)

// queueOrder 记同一份列表里上一次看到的位置。调用方自己持锁(各家一把,互不相干)。
type queueOrder struct {
	list     string // 列表身份,由调用方定(QQ 用归档 mtime + 曲目数,酷狗用内容摘要)
	pos      int
	shuffled bool
}

// observe 记下这一次的位置,返回此刻是否按随机处理;flipped = 这一次刚从顺序翻成随机(给调用方打日志)。
// 同一首重复调用(暂停恢复)不算证据。
func (o *queueOrder) observe(list string, pos int) (shuffled, flipped bool) {
	prev := *o
	if prev.list != list {
		*o = queueOrder{list: list, pos: pos}
		return false, false
	}
	if pos == prev.pos {
		return prev.shuffled, false
	}
	shuffled = pos != prev.pos+1
	*o = queueOrder{list: list, pos: pos, shuffled: shuffled}
	return shuffled, shuffled && !prev.shuffled
}

// shuffleCandidates 是随机播放时交出去预解析的那一批(规则见 queueShuffleWholeListMax 头注)。
// at(i) 取列表第 i 首,ok=false 的跳过。顺序从当前往后、到末尾接回开头,当前这首不在里面。
func shuffleCandidates(size, pos int, at func(i int) (upcomingTrack, bool)) []upcomingTrack {
	var res []upcomingTrack
	whole := size <= queueShuffleWholeListMax
	for k := 1; k < size; k++ {
		t, ok := at((pos + k) % size)
		if !ok {
			continue
		}
		if !whole {
			if !upcomingNeedsResolve(t) {
				continue
			}
			if len(res) == queueShuffleBatch {
				break
			}
		}
		res = append(res, t)
	}
	return res
}

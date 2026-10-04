package main

import "log"

// migrateMultiCreditCanonicalArtists 清掉合唱串条目上的 canonical_artist。只有单一歌手才该有它(expectsCanonicalArtist);
// 合唱串上的值是按整串查中文名查出来的,是其中某一位歌手的名字,会被「歌词管理」当成这首歌的歌手显示。
// 查名字那几个入口已经不再给合唱串结果,这里只处理存量。幂等:清完就不再命中。
func migrateMultiCreditCanonicalArtists() {
	enrichMu.Lock()
	cleared := 0
	for k, e := range enrichCache {
		if e.CanonicalArtist == "" {
			continue
		}
		artist, _, _ := splitEnrichKey(k)
		if expectsCanonicalArtist(artist) {
			continue
		}
		e.CanonicalArtist = ""
		enrichCache[k] = e
		cleared++
	}
	if cleared > 0 {
		enrichDirty = true
	}
	enrichMu.Unlock()
	if cleared > 0 {
		log.Printf("multi-credit canonical migration: cleared canonical_artist on %d entries", cleared)
		saveEnrichCache()
	}
}

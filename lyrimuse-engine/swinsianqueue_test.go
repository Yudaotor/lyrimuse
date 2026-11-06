package main

import "testing"

// Swinsian 的队列从当前这首起;取往后几首,单曲循环不预取,问不到退回同专辑预取。
func TestSwinsianUpcoming(t *testing.T) {
	saved := swinsianQueueAsk
	defer func() { swinsianQueueAsk = saved }()
	reply := `{"current_index":0,"repeating":"off","tracks":[` +
		`{"title":"Orange Moon","artist":"方大同","album":"橙月","duration":335.5},` +
		`{"title":"红豆","artist":"王菲","album":"唱游","duration":256,"path":"/m/b.mp3"},` +
		`{"title":"Karma","artist":"AJR","album":"","duration":203}]}`
	swinsianQueueAsk = func() (string, bool) { return reply, true }
	got, ok := swinsianUpcoming("方大同", "Orange Moon", 5)
	if !ok || len(got) != 2 || got[0].title != "红豆" || got[0].album != "唱游" || got[0].path != "/m/b.mp3" || got[1].artist != "AJR" {
		t.Fatalf("swinsianUpcoming = %+v, %v", got, ok)
	}
	swinsianQueueAsk = func() (string, bool) {
		return `{"current_index":0,"repeating":"one","tracks":[{"title":"Orange Moon","artist":"方大同"},{"title":"红豆","artist":"王菲"}]}`, true
	}
	if got, ok := swinsianUpcoming("方大同", "Orange Moon", 5); !ok || len(got) != 0 {
		t.Errorf("单曲循环时不该有预取: %+v, %v", got, ok)
	}
	swinsianQueueAsk = func() (string, bool) { return "", false }
	if _, ok := swinsianUpcoming("方大同", "Orange Moon", 5); ok {
		t.Error("问不到时应退回同专辑预取")
	}
}

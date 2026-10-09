package main

import (
	"reflect"
	"sort"
	"strings"
	"testing"
)

// enrichEntry 的每个 JSON 键都登记了归属;登记表里没有已经不存在的键。加了字段就在 songEntityFieldClasses 里登记它属于哪一级。
func TestSongEntityFieldsRegistered(t *testing.T) {
	keys := map[string]bool{}
	typ := reflect.TypeOf(enrichEntry{})
	for i := range typ.NumField() {
		name, _, _ := strings.Cut(typ.Field(i).Tag.Get("json"), ",")
		if name == "" || name == "-" {
			continue
		}
		keys[name] = true
	}
	var missing, stale []string
	for k := range keys {
		if songEntityFieldClasses[k] == "" {
			missing = append(missing, k)
		}
	}
	for k := range songEntityFieldClasses {
		if !keys[k] {
			stale = append(stale, k)
		}
	}
	sort.Strings(missing)
	sort.Strings(stale)
	if len(missing) > 0 {
		t.Errorf("这些字段没登记归属(在 songEntityFieldClasses 里登记它属于哪一级、同步时跟不跟着走): %v", missing)
	}
	if len(stale) > 0 {
		t.Errorf("登记表里这些键在 enrichEntry 上已经没有了: %v", stale)
	}
	if len(keys) < 80 {
		t.Fatalf("只枚举到 %d 个键,守卫自己没跑对", len(keys))
	}
}

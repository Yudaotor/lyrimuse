package main

import (
	"context"
	"testing"
)

// hanOnlyPortion 的判据——见其声明处头注(曹格《Superman》专辑"妳是我的寶貝"真实bug:
// 本地标签"Gary 曹格"八个源全部搜不到,单独查"曹格"四个源立刻命中,分数都在1100+)。
func TestHanOnlyPortion(t *testing.T) {
	cases := []struct{ in, want, why string }{
		{"Gary 曹格", "曹格", "英文名+中文名拼接,取中文段"},
		{"Jay Chou", "", "全是拉丁字母,没有汉字,不适用"},
		{"陶喆", "", "全是汉字,没有拉丁字母——不该跟这条混,那是别的问题"},
		{"陶喆和盧廣仲", "", "全是汉字(含'和'这个连接词),没有拉丁字母,不归这条管"},
		{"A 字", "", "中文段只有1个字,不够格当名字"},
		{"X 曹格 Y 曹格格格", "曹格格格", "多段汉字时取最长的一段"},
		{"", "", "空串"},
		{"Gary", "", "只有拉丁字母,没有汉字"},
	}
	for _, c := range cases {
		if got := hanOnlyPortion(c.in); got != c.want {
			t.Errorf("hanOnlyPortion(%q) = %q, want %q (%s)", c.in, got, c.want, c.why)
		}
	}
}

// retryArtistIdentities 接上 hanOnlyPortion 之后的端到端行为——真实案例复现。
func TestRetryArtistIdentitiesHanOnlyPortion(t *testing.T) {
	withCachedAliases(t, map[string]string{"Gary 曹格": ""})
	withCachedMBAliases(t, map[string][]string{"Gary 曹格": nil})
	withCachedQQArtistNames(t, map[string]string{"Gary 曹格": ""})

	got := retryArtistIdentities(context.Background(), "Gary 曹格")
	found := false
	for _, s := range got {
		if s == "曹格" {
			found = true
		}
	}
	if !found {
		t.Fatalf(`retryArtistIdentities("Gary 曹格") = %v, 应该包含 "曹格"`, got)
	}
}

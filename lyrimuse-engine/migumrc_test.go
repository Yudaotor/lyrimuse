package main

import (
	"strings"
	"testing"
)

// miguMRCFixtureHex 是下面这段明文按客户端算法加密出来的 MRC 文件正文。
const miguMRCFixtureHex = "31c1161be5ad108cd8f1bfa976753ccfdfd4aa7b97188cbd5a7322a000333da1450b36bc4312671a92eb81bf0e4f65e76c1e794348ec171093d0f8ead4e5a833ce520af3e26961d0b65482da18f5da530f612f25ff1508f19d4135f0123b1350f2188d0f3fed36648591dca314cba5e18e0c6c01228bacd1540e5cfa30badac6486bdb0cd5592b7cc792a3ce085eb6312dc371b310204eb1b34f63ca16677911676190ae50844901700370217fb91abb0bfa5f3c783c43fc2e50f562fb655c06eea2b6be832ba9b6dfed68e89eff328d7ac23e5864b743b2468b43e49293dd60ea36e5aebae83985e8a05e6ed7161c00"

const miguMRCFixturePlain = "[ti:测试]\n[0,0]测(0,0)试(0,0)\n[1000,900]你(1000,300)好(1300,300)世(1600,150)界(1750,150)\n[2500,600]Hel(2500,300)lo(2800,300)\n"

func TestMiguDecryptMRC(t *testing.T) {
	got, err := miguDecryptMRC(miguMRCFixtureHex)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if got != miguMRCFixturePlain {
		t.Fatalf("got %q, want %q", got, miguMRCFixturePlain)
	}
	if _, err := miguDecryptMRC("zz"); err == nil {
		t.Fatal("too-short body must fail")
	}
	if _, err := miguDecryptMRC(strings.Repeat("g", 32)); err == nil {
		t.Fatal("non-hex body must fail")
	}
}

func TestMiguMRCToYRC(t *testing.T) {
	got := miguMRCToYRC(miguMRCFixturePlain)
	lines := strings.Split(strings.TrimSpace(got), "\n")
	if len(lines) != 2 {
		t.Fatalf("want 2 lines ([0,0] header dropped), got %d:\n%s", len(lines), got)
	}
	if strings.Contains(got, "测") {
		t.Fatalf("[0,0] line leaked: %s", got)
	}
	if !strings.HasPrefix(lines[0], "[1000,900]") || !strings.Contains(lines[0], "(1000,300,0)你") ||
		!strings.Contains(lines[0], "(1750,150,0)界") {
		t.Errorf("line 0 not converted to YRC: %s", lines[0])
	}
	if !strings.HasPrefix(lines[1], "[2500,600]") || !strings.Contains(lines[1], "(2800,300,0)lo") {
		t.Errorf("line 1 not converted to YRC: %s", lines[1])
	}
	if miguMRCToYRC("[ti:x]\n[0,0]标(0,0)题(0,0)\n") != "" {
		t.Error("header-only MRC must yield empty")
	}
}

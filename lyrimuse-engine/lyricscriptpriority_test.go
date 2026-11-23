package main

import (
	"fmt"
	"strings"
	"testing"
)

var (
	scriptGreekLines = []string{"Δώδεκα", "Κι ούτε ένα τηλεφώνημα", "Τον αριθμό της μοναξιάς μου δε χτυπάς",
		"Και μεγαλώνει η απόσταση για μας", "Δώδεκα", "Κι ούτε ένα τηλεφώνημα", "Μες στου μυαλού μου το αβάσταχτο κενό",
		"Μοιάζεις με όνειρο που φεύγει μακρινό", "Και δε χτυπάει το τηλέφωνο", "Με πνίγει το παράπονο",
		"Που δεν κατάλαβες ποτέ σου τι περνώ", "Κι αν έχει γίνει η αγωνία μου βουνό", "Η ελπίδα μου κρεμάστηκε",
		"Σ' ένα τηλέφωνο που έμεινε νεκρό"}
	scriptGreeklishLines = []string{"Dodeka", "Ki out' ena tilefonima", "Ton arithmo tis monaksias mou den xtypas",
		"Kai megalonei I apostasi gia mas", "Dodeka", "Ki out' ena tilefonima", "Mes stou myalou mou to avastaxto keno",
		"Moiazeis me oneiro pou feygei makrino", "Ma de xtypaei to tilefono", "Me pnigei to parapono",
		"Pou den katalaves pote sou ti perno", "Ki an exei ginei I agonia mou vouno", "I elpida mou kremastike",
		"S'ena tilefono pou emeine nekro"}
	scriptPersianLines = []string{"حالا که کار تو شده", "پر از نیرنگ و ریا", "حالا که دل تو شده", "فرسنگها دور از خدا",
		"به من نگو دوستت دارم", "که باورم نمیشه", "نگو فقط تو رو دارم", "که باورم نمیشه", "تو بااین چرب زبونی",
		"هی به من دروغ میگی", "میخواهی گولم بزنی", "هی به من دروغ میگی", "به من نگو دوستت دارم", "که باورم نمیشه"}
	scriptFinglishLines = []string{"Hala keh kare to shode", "por az neyrango riya", "hala ke dele to shode",
		"farsangha door az khoda", "Be man nagoo dooset daram", "keh bavaram nemishe", "nagoo faghat toro daram",
		"keh bavaram nemishe", "to ba in charb zabooni", "hey be man dooroogh migi", "mikhay goolam bezani",
		"hey be man dooroogh migi", "be man nagoo dooset daram", "keh bavaram nemishe"}
	scriptEnglishLines = []string{"I walked along the river in the morning light", "Every window open and the city waking slow",
		"You said we had forever but forever had to go", "Now the trains are running empty through the night",
		"Hold on to the feeling when the summer turns to grey", "Tell me that you're coming back and never go away",
		"All the letters in the drawer are fading into white", "Hold on to the feeling when the summer turns to grey",
		"Every word you ever said is ringing in my head", "Running down the hallway with the candles burning red",
		"Tell me that you're coming back and never go away", "I walked along the river in the morning light",
		"Every window open and the city waking slow", "You said we had forever but forever had to go"}
	scriptKanaLines = []string{"夢ならばどれほどよかったでしょう", "未だにあなたのことを夢にみる", "忘れた物を取りに帰るように",
		"古びた思い出の埃を払う", "戻らない幸せがあることを", "最後にあなたが教えてくれた", "言えずに隠してた昏い過去も",
		"あなたがいなきゃ永遠に昏いまま", "きっともうこれ以上 傷つくことなど", "ありはしないとわかっている",
		"あの日の悲しみさえ", "あの日の苦しみさえ", "そのすべてを愛してた あなたとともに", "胸に残り離れない"}
	scriptRomajiLines = []string{"Yume naraba dore hodo yokatta deshou", "Imada ni anata no koto wo yume ni miru",
		"Wasureta mono wo tori ni kaeru you ni", "Furubita omoide no hokori wo harau", "Modoranai shiawase ga aru koto wo",
		"Saigo ni anata ga oshiete kureta", "Iezu ni kakushiteta kurai kako mo", "Anata ga inakya eien ni kurai mama",
		"Kitto mou kore ijou kizutsuku koto nado", "Ari wa shinai to wakatte iru", "Ano hi no kanashimi sae",
		"Ano hi no kurushimi sae", "Sono subete wo aishiteta anata to tomo ni", "Mune ni nokori hanarenai"}
	scriptDevanagariLines = []string{"तुम से तुम तक का सफ़र", "दिल ने तय किया है मगर", "हर कदम पे तेरा ही नाम",
		"हर सुबह हर एक शाम", "तू ही मेरी ज़िंदगी", "तू ही मेरी बंदगी", "कैसे कहूँ मैं तुझसे यार", "तुझसे ही है मेरा प्यार",
		"तुम से तुम तक का सफ़र", "दिल ने तय किया है मगर", "हर कदम पे तेरा ही नाम", "हर सुबह हर एक शाम",
		"तू ही मेरी ज़िंदगी", "तू ही मेरी बंदगी"}
	scriptHinglishLines = []string{"Tum se tum tak ka safar", "Dil ne tay kiya hai magar", "Har kadam pe tera hi naam",
		"Har subah har ek shaam", "Tu hi meri zindagi", "Tu hi meri bandagi", "Kaise kahun main tujhse yaar",
		"Tujhse hi hai mera pyaar", "Tum se tum tak ka safar", "Dil ne tay kiya hai magar", "Har kadam pe tera hi naam",
		"Har subah har ek shaam", "Tu hi meri zindagi", "Tu hi meri bandagi"}
	scriptCyrillicCoverLines = []string{"Я иду по городу один", "Фонари горят в ночной тиши", "Ты сказала что вернёшься днём",
		"Только ветер воет за окном", "Где-то там над крышами зима", "Я тебя искал но не нашёл", "Сердце бьётся тише и тише",
		"Снег ложится на пустой перрон", "Я иду по городу один", "Фонари горят в ночной тиши", "Ты сказала что вернёшься днём",
		"Только ветер воет за окном", "Где-то там над крышами зима", "Я тебя искал но не нашёл"}
	scriptTurkishLines = []string{"Gel gör beni aşk neyledi", "Derde giriftar eyledi", "Ben yürürüm yane yane",
		"Aşk boyadı beni kane", "Ne âkilim ne divane", "Gel gör beni aşk neyledi", "Kâh eserim yeller gibi",
		"Kâh tozarım yollar gibi", "Kâh akarım seller gibi", "Gel gör beni aşk neyledi", "Ben yürürüm yane yane",
		"Aşk boyadı beni kane", "Ne âkilim ne divane", "Gel gör beni aşk neyledi"}
	scriptMalayalamLines = []string{"എൻ കൺമണി കൺമണി കണ്ണുകളെന്നെ കാണുന്നില്ലേ", "കാണാത്തൊരു ദൈവത്തെ കാണാൻ കണ്ണുള്ളവളെ",
		"കണ്മുന്നിൽ ഞാൻ നിന്നിട്ടും അറിയുന്നില്ലല്ലേ", "കണ്ണിൽ കർപ്പൂര ദീപമോ ശ്രീവല്ലി", "വാക്കിൽ കല്യാണി രാഗമോ",
		"മെയ്യിൽ കസ്തൂരി ഗന്ധമോ"}
	scriptTeluguTranslitLines = []string{"Ninu Choosthu Unte Kannulu", "Rendu Thippesthave", "Nee Choopula Paine",
		"Reppalu Vesi Kappesthave", "Kanipinchani Devudne", "Kannaarpaka Choosthave"}
)

// scriptLRC:每句隔 8 秒,从 12 秒起。
func scriptLRC(lines []string) string {
	var b strings.Builder
	for i, l := range lines {
		ms := 12000 + 8000*i
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", ms/60000, ms/1000%60, ms%1000/10, l)
	}
	return b.String()
}

// scriptYRC:同 scriptLRC 的逐字轴,每句一个词、唱 3 秒。
func scriptYRC(lines []string) string {
	var b strings.Builder
	for i, l := range lines {
		ms := 12000 + 8000*i
		fmt.Fprintf(&b, "[%d,3000](%d,3000,0)%s\n", ms, ms, l)
	}
	return b.String()
}

// scriptDur:曲长,末句之后留 6 秒。
func scriptDur(lines []string) float64 { return float64(12+8*(len(lines)-1)) + 6 }

func scriptCand(source string, lines []string, score int, terms ...any) scoredLyricCandidateResult {
	return scoredLyricCandidateResult{Source: source, Lyrics: scriptLRC(lines), Score: score, ScoreTerms: yieldTerms(terms...)}
}

func TestLyricWritingSystem(t *testing.T) {
	for _, tc := range []struct {
		lines []string
		want  writingSystem
		urdu  bool
	}{
		{scriptGreekLines, wsGreek, false}, {scriptGreeklishLines, wsLatin, false}, {scriptPersianLines, wsArabic, false},
		{scriptDevanagariLines, wsDevanagari, false}, {scriptMalayalamLines, wsMalayalam, false},
		{scriptTurkishLines, wsLatin, false}, {scriptCyrillicCoverLines, wsCyrillic, false},
		{[]string{"دل پے زخم کھاتے ہیں", "جان سے گزرتے ہیں", "جرم صرف اتنا ہے", "ان کو پیار کرتے ہیں"}, wsArabic, true},
		{[]string{"Hello world", "Привет мир", "Γεια σου κόσμε", "שלום עולם"}, wsNone, false},
	} {
		ws, urdu := lyricWritingSystem(scriptLRC(tc.lines))
		if ws != tc.want || urdu != tc.urdu {
			t.Errorf("%q…:得到 %v/%v,该是 %v/%v", tc.lines[0], ws, urdu, tc.want, tc.urdu)
		}
	}
	if !nativePriorityScript(wsArabic, false) || nativePriorityScript(wsArabic, true) || nativePriorityScript(wsDevanagari, false) ||
		!nativePriorityScript(wsGreek, false) || !nativePriorityScript(wsCyrillic, false) || !nativePriorityScript(wsHebrew, false) ||
		nativePriorityScript(wsLatin, false) || nativePriorityScript(wsThai, false) {
		t.Error("原文优先只管希腊、西里尔、阿拉伯(不含乌尔都)、希伯来字母")
	}
}

func TestTransliterationSimilarity(t *testing.T) {
	greek, persian := scriptLRC(scriptGreekLines), scriptLRC(scriptPersianLines)
	if s := transliterationSimilarity(greek, wsGreek, scriptLRC(scriptGreeklishLines)); s < transliterationMinSimilarity {
		t.Errorf("希腊字母原文和它的转写:重合度 %.2f,该过线", s)
	}
	if s := transliterationSimilarity(persian, wsArabic, scriptLRC(scriptFinglishLines)); s < transliterationMinSimilarity {
		t.Errorf("波斯文原文和它的转写:重合度 %.2f,该过线", s)
	}
	for name, latin := range map[string][]string{"英文": scriptEnglishLines, "土耳其文": scriptTurkishLines, "另一首的转写": scriptFinglishLines} {
		if s := transliterationSimilarity(greek, wsGreek, scriptLRC(latin)); s >= transliterationMinSimilarity {
			t.Errorf("希腊字母原文对%s:重合度 %.2f,不该过线", name, s)
		}
	}
	if s := transliterationSimilarity(scriptLRC(scriptGreekLines[:3]), wsGreek, scriptLRC(scriptGreeklishLines[:3])); s != 0 {
		t.Errorf("骨架太短的不比,得到 %.2f", s)
	}
	var mixed []string
	for i := range scriptGreekLines {
		mixed = append(mixed, scriptGreekLines[i], scriptGreeklishLines[i])
	}
	if lyricsTransliterate(scriptLRC(mixed), greek) {
		t.Error("原文和转写对照着写的不算转写")
	}
	if got := nativeSkeleton(scriptLRC([]string{"که شده دوستت"}), wsArabic); len(got) != 1 || got[0] != "K ST TSTT" {
		t.Errorf("波斯文骨架:词尾的 ه 不算,得到 %q", got)
	}
	if got := latinSkeleton(scriptLRC([]string{"keh shode doosetet"}), wsArabic); len(got) != 1 || got[0] != "K ST TSTT" {
		t.Errorf("波斯文转写骨架:词尾的 h 不算,得到 %q", got)
	}
	if got := latinSkeleton(scriptLRC([]string{"xtypas 8eos psyxi"}), wsGreek); len(got) != 1 || got[0] != "KTBS TS BSK" {
		t.Errorf("希腊文转写骨架,得到 %q", got)
	}
	if !lyricsTransliterate(scriptLRC(scriptGreeklishLines), greek) || lyricsTransliterate(greek, scriptLRC(scriptGreeklishLines)) ||
		lyricsTransliterate(scriptLRC(scriptRomajiLines), scriptLRC(scriptKanaLines)) ||
		lyricsTransliterate(scriptLRC(scriptHinglishLines), scriptLRC(scriptDevanagariLines)) {
		t.Error("lyricsTransliterate 只认原文优先那几套文字的拉丁转写")
	}
}

func scriptWinner(results []scoredLyricCandidateResult) scoredLyricCandidateResult {
	best := results[0]
	for _, r := range results[1:] {
		if r.Score > best.Score {
			best = r
		}
	}
	return best
}

func TestApplyNativeScriptPriority(t *testing.T) {
	dur := func(p int) []any {
		return []any{scoreTermDuration, p, scoreTermLines, 14, scoreTermTitleMatch, 120}
	}
	t.Run("逐字转写压不过可信的原文", func(t *testing.T) {
		for _, pair := range [][2][]string{{scriptGreekLines, scriptGreeklishLines}, {scriptPersianLines, scriptFinglishLines}} {
			rs := []scoredLyricCandidateResult{
				scriptCand("kuwo", pair[1], 1300, append(dur(226), scoreTermWordTiming, 400, scoreTermConsensus, 250)...),
				scriptCand("qq", pair[1], 1250, append(dur(226), scoreTermWordTiming, 400, scoreTermConsensus, 250)...),
				scriptCand("lrclib", pair[0], 401, dur(226)...),
			}
			applyNativeScriptPriority(rs)
			if w := scriptWinner(rs); w.Source != "lrclib" {
				t.Fatalf("该选原文,得到 %s %+v", w.Source, rs)
			}
			if rs[0].Score != 400 || scoreTermPoints(rs[0].ScoreTerms, scoreTermVersionTags) != -900 {
				t.Fatalf("转写该正好压到原文之下 1 分: %+v", rs[0])
			}
			if rs[1].Score > rs[0].Score {
				t.Fatalf("转写之间的先后照旧: %+v", rs)
			}
		}
	})
	t.Run("压到最好的那份原文之下", func(t *testing.T) {
		rs := []scoredLyricCandidateResult{
			scriptCand("kuwo", scriptGreeklishLines, 1500, append(dur(226), scoreTermWordTiming, 400)...),
			scriptCand("lrclib", scriptGreekLines, 701, dur(226)...),
			scriptCand("deezer", scriptGreekLines, 300, dur(226)...),
		}
		applyNativeScriptPriority(rs)
		if rs[0].Score != 700 {
			t.Fatalf("得到 %+v", rs[0])
		}
	})
	t.Run("原文和转写对照着写的不扣", func(t *testing.T) {
		var mixed []string
		for i := range scriptGreekLines {
			mixed = append(mixed, scriptGreekLines[i]+" / "+scriptGreeklishLines[i])
		}
		rs := []scoredLyricCandidateResult{scriptCand("kuwo", mixed, 1200, append(dur(226), scoreTermWordTiming, 400)...),
			scriptCand("lrclib", scriptGreekLines, 401, dur(226)...)}
		applyNativeScriptPriority(rs)
		if rs[0].Score != 1200 {
			t.Fatalf("得到 %+v", rs[0])
		}
	})
	t.Run("至少扣 versionMismatchPenalty", func(t *testing.T) {
		rs := []scoredLyricCandidateResult{
			scriptCand("kuwo", scriptGreeklishLines, 700, append(dur(226), scoreTermWordTiming, 400)...),
			scriptCand("lrclib", scriptGreekLines, 650, dur(226)...),
		}
		applyNativeScriptPriority(rs)
		if rs[0].Score != 100 {
			t.Fatalf("得到 %+v", rs[0])
		}
	})
	t.Run("只有转写版时照常用转写版", func(t *testing.T) {
		for name, native := range map[string]scoredLyricCandidateResult{
			"原文时长对不上":   scriptCand("lrclib", scriptGreekLines, 1, scoreTermDurationOff, -500, scoreTermLines, 14),
			"原文版本不符":    scriptCand("lrclib", scriptGreekLines, 1, append(dur(226), scoreTermVersionTags, -600)...),
			"原文没有时长项":   scriptCand("lrclib", scriptGreekLines, 134, scoreTermLines, 14, scoreTermTitleMatch, 120),
			"原文判废":      scriptCand("lrclib", scriptGreekLines, -1, scoreRejectPlainTextOnly, 0),
			"原文行数差太多":   scriptCand("lrclib", scriptGreekLines[:7], 360, dur(226)...),
			"转写行数是原文两倍": scriptCand("lrclib", scriptGreekLines, 401, dur(226)...),
		} {
			latin := scriptGreeklishLines
			if name == "转写行数是原文两倍" {
				latin = append(append([]string(nil), scriptGreeklishLines...), scriptGreeklishLines...)
			}
			rs := []scoredLyricCandidateResult{scriptCand("kuwo", latin, 949, append(dur(226), scoreTermWordTiming, 400)...), native}
			applyNativeScriptPriority(rs)
			if rs[0].Score != 949 {
				t.Errorf("%s:转写不该扣分,得到 %+v", name, rs[0])
			}
		}
		rs := []scoredLyricCandidateResult{scriptCand("kuwo", scriptGreeklishLines, 949, append(dur(226), scoreTermWordTiming, 400)...)}
		applyNativeScriptPriority(rs)
		if rs[0].Score != 949 {
			t.Errorf("只有转写一份:得到 %+v", rs[0])
		}
	})
	t.Run("拉丁字母本来就是正常写法的不动", func(t *testing.T) {
		for name, pair := range map[string][2][]string{
			"日文罗马音":      {scriptKanaLines, scriptRomajiLines},
			"Hinglish":   {scriptDevanagariLines, scriptHinglishLines},
			"土耳其文对俄文翻唱":  {scriptCyrillicCoverLines, scriptTurkishLines},
			"英文对另一首希腊歌":  {scriptGreekLines, scriptEnglishLines},
			"另一首歌的波斯文转写": {scriptGreekLines, scriptFinglishLines},
		} {
			rs := []scoredLyricCandidateResult{
				scriptCand("qq", pair[1], 1000, append(dur(226), scoreTermWordTiming, 400)...),
				scriptCand("lrclib", pair[0], 500, dur(226)...),
			}
			applyNativeScriptPriority(rs)
			if rs[0].Score != 1000 || rs[1].Score != 500 {
				t.Errorf("%s:分数不该变,得到 %+v", name, rs)
			}
		}
	})
	t.Run("乌尔都文不算原文优先", func(t *testing.T) {
		urdu := []string{"دل پے زخم کھاتے ہیں جان سے گزرتے ہیں", "جرم صرف اتنا ہے ان کو پیار کرتے ہیں", "ایسا دیکھا نہیں خوبصورت کوئی",
			"جسم جیسے اجنتا کی مورت کوئی", "جسم جیسے نگاہوں پہ جادو کوئی", "دل پے زخم کھاتے ہیں جان سے گزرتے ہیں",
			"جرم صرف اتنا ہے ان کو پیار کرتے ہیں", "ایسا دیکھا نہیں خوبصورت کوئی"}
		latin := []string{"Dil pe zakhm khate hain jaan se guzarte hain", "Jurm sirf itna hai un ko pyar karte hain",
			"Aisa dekha nahin khoobsurat koi", "Jism jaise ajanta ki moorat koi", "Jism jaise nigahon pe jadoo koi",
			"Dil pe zakhm khate hain jaan se guzarte hain", "Jurm sirf itna hai un ko pyar karte hain", "Aisa dekha nahin khoobsurat koi"}
		rs := []scoredLyricCandidateResult{scriptCand("qq", latin, 1000, append(dur(226), scoreTermWordTiming, 400)...), scriptCand("netease", urdu, 500, dur(226)...)}
		applyNativeScriptPriority(rs)
		if rs[0].Score != 1000 {
			t.Errorf("得到 %+v", rs[0])
		}
	})
}

// 两条流水线(首轮排序、合并轮重打分)都接上了原文优先和语种标记。
func TestScriptRulesWiredIntoRanking(t *testing.T) {
	artist, title, album := "Anna Vissi", "Dodeka", "The Love Collection"
	d := scriptDur(scriptGreekLines)
	raw := map[string]lyricSourceResult{
		"lrclib": {source: "lrclib", lyr: scriptLRC(scriptGreekLines), srcDur: d, matchTitle: title, matchArtist: artist},
		"kuwo": {source: "kuwo", lyr: scriptLRC(scriptGreeklishLines), yrc: scriptYRC(scriptGreeklishLines), srcDur: d,
			matchTitle: title, matchArtist: artist, matchAlbum: album},
	}
	check := func(stage string, got []scoredLyricCandidateResult) {
		t.Helper()
		if len(got) < 2 || got[0].Source != "lrclib" || scoreTermPoints(got[1].ScoreTerms, scoreTermVersionTags) >= 0 {
			t.Fatalf("%s:原文该排第一、转写扣版本不符,得到 %+v", stage, got)
		}
	}
	first := rankLyricSourceResults(artist, title, album, d, raw)
	check("首轮", first)
	check("合并重打分", mergeLyricCandidateRounds(artist, title, album, d, first, nil))

	md := scriptDur(scriptMalayalamLines)
	dub := map[string]lyricSourceResult{
		"lrclib": {source: "lrclib", lyr: scriptLRC(scriptMalayalamLines), srcDur: md, matchTitle: "Srivalli", matchArtist: "Sid Sriram"},
		"kuwo":   {source: "kuwo", lyr: scriptLRC(scriptTeluguTranslitLines), srcDur: md, matchTitle: "Srivalli", matchArtist: "Sid Sriram"},
	}
	for _, tc := range []struct {
		album, want string
	}{{"Pushpa - The Rise (Telugu) [Original Motion Picture Soundtrack]", "kuwo"}, {"Pushpa - The Rise (Original Motion Picture Soundtrack)", "lrclib"}} {
		dubFirst := rankLyricSourceResults("Sid Sriram", "Srivalli", tc.album, md, dub)
		for stage, got := range map[string][]scoredLyricCandidateResult{"首轮": dubFirst,
			"合并重打分": mergeLyricCandidateRounds("Sid Sriram", "Srivalli", tc.album, md, dubFirst, nil)} {
			if len(got) == 0 || got[0].Source != tc.want {
				t.Errorf("%s %s:该选 %s,得到 %+v", tc.album, stage, tc.want, got)
			}
		}
	}
}

func TestDeclaredLanguage(t *testing.T) {
	for _, tc := range []struct{ title, album, want string }{
		{"Srivalli", "Pushpa - The Rise (Telugu) [Original Motion Picture Soundtrack]", "telugu"},
		{`Srivalli (From "Pushpa - The Rise (Malayalam)")`, "", "malayalam"},
		{"Veezha Veera [Tamil]", "", "tamil"},
		{"Naatu Naatu (Hindi Version)", "", "hindi"},
		{"Kesariya - Hindi Version", "", "hindi"},
		{"Song", "Album - Kannada", "kannada"},
		{"Srivalli", "Pushpa - The Rise (Original Motion Picture Soundtrack)", ""},
		{"Song", "Best of Tamil Hits", ""},
		{"Song (Telugu)", "Album (Tamil)", ""},
		{"Hindi Zahra", "", ""},
	} {
		if got := declaredLanguage(tc.title, tc.album); got != tc.want {
			t.Errorf("%q / %q:得到 %q,该是 %q", tc.title, tc.album, got, tc.want)
		}
	}
}

func TestApplyScriptMarkerVerdicts(t *testing.T) {
	cands := func() []lyricCandidate {
		return []lyricCandidate{
			{source: "lrclib", lyrics: scriptLRC(scriptMalayalamLines)},
			{source: "deezer", lyrics: scriptLRC(scriptDevanagariLines)},
			{source: "kuwo", lyrics: scriptLRC(scriptTeluguTranslitLines)},
			{source: "qq", lyrics: scriptLRC([]string{"Hello world", "Привет мир", "Γεια σου κόσμε", "שלום עולם"})},
		}
	}
	got := cands()
	applyScriptMarkerVerdicts("Srivalli", "Pushpa - The Rise (Telugu)", got)
	if !got[0].languageVersionMismatch || !got[1].languageVersionMismatch || got[2].languageVersionMismatch || got[3].languageVersionMismatch {
		t.Fatalf("标了泰卢固语:马拉雅拉姆文、天城文判不符,拉丁字母和混写不判,得到 %+v", got)
	}
	got = cands()
	applyScriptMarkerVerdicts("Srivalli", "Pushpa - The Rise (Original Motion Picture Soundtrack)", got)
	for _, c := range got {
		if c.languageVersionMismatch {
			t.Fatalf("没有语种标记时不判: %+v", c)
		}
	}
	got = cands()
	applyScriptMarkerVerdicts("Song (Hindi Version)", "", got)
	if !got[0].languageVersionMismatch || got[1].languageVersionMismatch {
		t.Fatalf("标了印地语:天城文对、马拉雅拉姆文不对,得到 %+v", got)
	}
	urdu := []lyricCandidate{{lyrics: scriptLRC(scriptDevanagariLines)}, {lyrics: scriptLRC(scriptPersianLines)}}
	applyScriptMarkerVerdicts("Afreen (Urdu)", "", urdu)
	if urdu[0].languageVersionMismatch || urdu[1].languageVersionMismatch {
		t.Fatalf("乌尔都语歌天城文、阿拉伯字母都允许: %+v", urdu)
	}
}

func TestIsSolfegeNotation(t *testing.T) {
	notation := scriptLRC([]string{"सा नी धा गा नी नि धा", "धा नी सा गा मा गा सा", "सा गा मा गा धा धा धा नी",
		"नी धा पा पा धा मा मा पा गा", "गा रे गा मा गा पा मा गा रे", "सा नी धा गा नी नि धा"})
	latin := "Sa Ni Dha Ga Ni Ni Ni Dha\nDha Ni Sa Ga Ma Ga Sa\nSa Ga Ma Ga Dha Dha Ma Dha Ni\nNi Dha Pa, Pa Dha Ma\nGa Re Ga Ma Ga\n"
	mixed := scriptLRC([]string{"सा नी धा गा नी नि धा", "धा नी सा गा मा गा सा", "आफरीन आफरीन", "हुस्न ए जाना की तारीफ़ मुमकिन नहीं",
		"तू भी देखे अगर तो कहे हमनशीं", "सा नि धा नि धा गा सा नि धा नि धा गा (आफरीन आफरीन )", "ऐसा देखा नहीं खूबसूरत कोई",
		"जिस्म जैसे अजंता की मूरत कोई"})
	tamil := scriptLRC([]string{"ப நி ச நி ப நி த ப ம க ச", "ம ச ரி க ச ரி ரி க ச ரி", "Moving to the rhythm of the beat, beat",
		"Move to the rhythm that'll dance all night", "க க ரி ச நி ச ரி", "ம ச ரி க ச ரி ரி க ச ரி"})
	for name, tc := range map[string]struct {
		s    string
		want bool
	}{
		"天城文唱名谱": {notation, true}, "拉丁唱名谱": {latin, true}, "唱名谱逐字": {scriptYRC(strings.Split(strings.TrimSpace(latin), "\n")), true},
		"夹着唱名段的歌词": {mixed, false}, "歌词夹唱名段占多数": {tamil, false},
		"拟声 pa pa": {scriptLRC([]string{"Pa pa pa ya", "Pa pa pa pa pa", "Pa pa pa ya", "Pa pa pa pa pa"}), false},
		"拟声 da da": {scriptLRC([]string{"da da da da da", "da da da da", "da da da da da", "da da da"}), false},
		"do re mi": {scriptLRC([]string{"Do re mi fa so la ti", "Do re mi fa so la ti", "Do re mi", "Doe a deer a female deer"}), false},
		"太短":       {scriptLRC([]string{"सा नी धा गा", "धा नी सा गा"}), false},
		"一行只有一种唱名": {scriptLRC([]string{"sa sa sa", "re re re", "ga ga ga", "ma ma ma", "pa pa pa"}), false},
		"一行两个词":    {scriptLRC([]string{"sa re", "ga ma", "pa dha", "ni sa", "re ga"}), false},
		"只用到三种唱名":  {scriptLRC([]string{"sa re sa re", "re ga re ga", "sa ga sa ga", "sa re ga", "ga re sa"}), false},
		"唱名夹着词":    {scriptLRC([]string{"sa re ga ma tujhe", "pa dha ni sa dil", "sa re ga ma tujhe", "pa dha ni sa dil", "ga ma pa dha yaar"}), false},
		"空":        {"", false},
	} {
		if got := isSolfegeNotation(tc.s); got != tc.want {
			t.Errorf("%s:得到 %v", name, got)
		}
	}
	r := decodeLyricSourceResultEntities(lyricSourceResult{lyr: notation, yrc: scriptYRC(strings.Split(strings.TrimSpace(latin), "\n")), tr: "x"})
	if r.lyr != "" || r.yrc != "" || r.tr != "x" {
		t.Fatalf("rank 门口该把唱名谱当成没有歌词: %+v", r)
	}
	if r := decodeLyricSourceResultEntities(lyricSourceResult{lyr: mixed}); r.lyr == "" {
		t.Fatal("夹着唱名段的歌词要留着")
	}
}

func TestRescoreDoesNotKeepTransliterationForWordTiming(t *testing.T) {
	picked := &scoredLyricCandidateResult{Source: "lrclib", Lyrics: scriptLRC(scriptGreekLines), Score: 401}
	e := enrichEntry{Lyrics: bt(scriptLRC(scriptGreeklishLines)), LyricsYRC: bt(scriptYRC(scriptGreeklishLines)), LyricsSource: "kuwo"}
	if rescoreWouldLoseWordTiming(e, []scoredLyricCandidateResult{*picked}, picked) {
		t.Fatal("当前是冠军原文的转写:丢逐字不算留着的理由")
	}
	e.Lyrics, e.LyricsYRC = bt(scriptLRC(scriptEnglishLines)), bt(scriptYRC(scriptEnglishLines))
	if !rescoreWouldLoseWordTiming(e, []scoredLyricCandidateResult{*picked}, picked) {
		t.Fatal("当前不是转写:照旧不丢逐字")
	}
}

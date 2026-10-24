import Foundation
import LyrimuseCore

/// 日 / 韩 / 中以外几种语言的读音:例词取自 UNGEGN 罗马化工作组各语言报告(4.0 版)给的地名例子
/// 和各标准的规则说明,见 10 章决策 49。
func checkWorldRomanization() {
    func cyr(_ text: String, _ language: CyrillicLanguage) -> String {
        CyrillicRomanization.romanize(text, language: language)
    }

    // ---- 俄语 GOST 1983 ----
    expectEqual(cyr("Щука", .russian), "Ščuka", "俄语: щ → šč,大写只大写第一个字母")
    expectEqual(cyr("объём", .russian), "ob\u{02BA}ëm", "俄语: ъ 写修饰字母双撇 ʺ、ё 写 ë")
    expectEqual(cyr("Съешь же ещё этих мягких французских булок", .russian),
                "S\u{02BA}eš\u{02B9} že eščë ètih mjagkih francuzskih bulok", "俄语: 全字母句逐字对表")

    // ---- 乌克兰语 2010 ----
    for (ua, latin) in [("Згорани", "Zghorany"), ("Розгон", "Rozghon"), ("Єнакієве", "Yenakiieve"),
                        ("Їжакевич", "Yizhakevych"), ("Йосипівка", "Yosypivka"), ("Стрий", "Stryi"),
                        ("Юрій", "Yurii"), ("Корюківка", "Koriukivka"), ("Яготин", "Yahotyn"),
                        ("Знам’янка", "Znamianka"), ("Гадяч", "Hadiach"), ("Щербухи", "Shcherbukhy")] {
        expectEqual(cyr(ua, .ukrainian), latin, "乌克兰语: \(ua) → \(latin)")
    }

    // ---- 保加利亚语 2009 ----
    expectEqual(cyr("Обичам България", .bulgarian), "Obicham Bulgaria", "保加利亚语: 国名按《音译法》例外写 Bulgaria")
    expectEqual(cyr("БЪЛГАРИЯ", .bulgarian), "BULGARIA", "保加利亚语: 国名例外整词大写")
    expectEqual(cyr("българин", .bulgarian), "balgarin", "保加利亚语: 只有国名本身例外")
    expectEqual(cyr("Казах ѝ, ѐ така", .bulgarian), "Kazah i, e taka", "保加利亚语: ѝ ѐ 按 и е 转")
    expectEqual(cyr("за́мок, мо\u{0301}ре", .russian), "zamok, more", "俄语: 标重音的元音去掉重音再转")
    expectEqual(cyr("Йод, Київ", .ukrainian), "Yod, Kyiv", "乌克兰语: й ї 的短音符、分音符不去")
    expectEqual(cyr("И\u{0306}од, Киі\u{0308}в", .ukrainian), "Yod, Kyiv", "乌克兰语: 存成「字母 + 组合符」的 й ї 先合成")
    expectEqual(cyr("Гу\u{0301}ска, ќе", .macedonian), "Guska, kje", "马其顿语: ќ 不被当成 к 加重音符")
    expectEqual(CyrillicRomanization.detectLanguage(String(repeating: "Казах ѝ, че те обичам. ", count: 4)), .bulgarian,
                "认语言: ѝ 不算外来字母")
    expectEqual(CyrillicRomanization.detectLanguage("Казах ѝ, че те обичам\nТи си моята любов и щастие"), .bulgarian,
                "认语言: 短的保加利亚歌靠 ѝ 跟俄语分开")
    for (bg, latin) in [("София", "Sofia"), ("Пловдив", "Plovdiv"), ("Търговище", "Targovishte"),
                        ("Илиянци", "Iliyantsi"), ("Ямбол", "Yambol"), ("Хасково", "Haskovo")] {
        expectEqual(cyr(bg, .bulgarian), latin, "保加利亚语: \(bg) → \(latin)")
    }

    // ---- 白俄罗斯语 2007 ----
    for (be, latin) in [("Беларусь", "Bielaruś"), ("Магілёў", "Mahilioŭ"), ("Віцебск", "Viciebsk"),
                        ("Гомель", "Homieĺ"), ("Брэст", "Brest"), ("Ельск", "Jeĺsk")] {
        expectEqual(cyr(be, .belarusian), latin, "白俄罗斯语: \(be) → \(latin)")
    }

    // ---- 塞尔维亚语 1977、马其顿语官方证件写法 ----
    expectEqual(cyr("Ђорђе Љубав Џеп", .serbian), "Đorđe Ljubav Džep", "塞尔维亚语: ђ љ џ")
    expectEqual(cyr("ЉУБАВ", .serbian), "LJUBAV", "塞尔维亚语: 整词大写时双字母也全大写")
    expectEqual(cyr("Ѓорѓи, ќе дојдеш", .macedonian), "Gjorgji, kje dojdesh", "马其顿语: ѓ gj、ќ kj、ш sh")
    expectEqual(cyr("Плакенска Планина", .macedonian), "Plakenska Planina", "马其顿语: 报告里的例子")
    expectEqual(cyr("Ѕвезда Џеп Жена Чаша Цвет", .macedonian), "Dzvezda Djep Zhena Chasha Cvet",
                "马其顿语: ѕ dz、џ dj、ж zh、ч ch、ц c")

    // ---- 哈萨克语 2021 年官方拉丁字母 ----
    for (kk, latin) in [("Қазақстан", "Qazaqstan"), ("Сәлем", "Sälem"), ("Көздерің сенің әп-әдемі", "Közderıñ senıñ äp-ädemı"),
                        ("Шын бақыт", "Şyn baqyt"), ("Ешкім жоқ", "Eşkım joq"), ("Ұлы Іле", "Ūly Ile"),
                        ("Иә", "İä"), ("ИӘ", "İÄ"), ("Юлия", "İuliia"), ("Ағылшын", "Ağylşyn"), ("Үй", "Üi"),
                        ("Цирк чай", "Tsirk tşai"), ("Өнер", "Öner"), ("Аи\u{0306}қын", "Aiqyn")] {
        expectEqual(cyr(kk, .kazakh), latin, "哈萨克语 2021: \(kk) → \(latin)")
    }

    // ---- 认语言 ----
    expectEqual(CyrillicRomanization.detectLanguage("Ты танцуешь, будто сумасшедшая"), .russian, "认语言: 俄语(ы)")
    expectEqual(CyrillicRomanization.detectLanguage("Чи прошепотів, щастя моє"), .ukrainian, "认语言: 乌克兰语(і є)")
    expectEqual(CyrillicRomanization.detectLanguage("Търговище и България са в сърцето ми"), .bulgarian,
                "认语言: 保加利亚语(ъ,没有 ы э)")
    expectEqual(CyrillicRomanization.detectLanguage("Магілёў і Беларусь"), .belarusian, "认语言: 白俄罗斯语(ў)")
    expectEqual(CyrillicRomanization.detectLanguage("Ђорђе Љубав"), .serbian, "认语言: 塞尔维亚语(ђ)")
    expectEqual(CyrillicRomanization.detectLanguage("Ѓорѓи Ќесендре"), .macedonian, "认语言: 马其顿语(ѓ ќ)")
    expectEqual(CyrillicRomanization.detectLanguage("Қазақстан"), .kazakh, "认语言: 哈萨克语(қ)")
    expectEqual(CyrillicRomanization.detectLanguage("Ошол күнү сенден уялганымдан сөз таппай"), nil,
                "认语言: 吉尔吉斯语(有 ң ө ү、没有 ә ғ қ ұ һ)不支持")
    expectEqual(CyrillicRomanization.detectLanguage(
        "Ты танцуешь ѕ будто сумасшедшая и ещё раз ты танцуешь будто сумасшедшая"), .russian,
                "认语言: 俄语歌夹一个形近的马其顿字母仍是俄语")
    expectEqual(CyrillicRomanization.detectLanguage("hello"), nil, "认语言: 没有西里尔字母")

    // ---- 希腊语 ELOT 743 转写版 ----
    for (el, latin) in [("Αθήνα", "Athína"), ("Θεσσαλονίκη", "Thessaloníki"), ("ΘΕΣΣΑΛΟΝΙΚΗ", "THESSALONIKI"),
                        ("ευχαριστώ", "efcharistó"), ("Ευρώπη", "Evrópi"), ("αυτοκίνητο", "aftokínito"),
                        ("Αύγουστος", "Ávgoustos"), ("Λαύριο", "Lávrio"), ("Ζευς", "Zefs"), ("μπαμπάς", "bampás"),
                        ("Μπέκας", "Békas"), ("άγγελος", "ángelos"), ("Σφίγγα", "Sfínga"), ("καΐκι", "kaḯki"),
                        ("Τι κάνεις\u{037E}", "Ti káneis?")] {
        expectEqual(GreekRomanization.romanize(el), latin, "希腊语: \(el) → \(latin)")
    }

    // ---- 印度系 ISO 15919 ----
    for (text, latin) in [("नमस्ते", "namastē"), ("हो गए", "hō gaē"), ("संगीत", "saṁgīta"), ("हूँ", "hū̃"), ("क्या", "kyā"),
                          ("दिल", "dila"), ("मैं", "maiṁ"), ("ज\u{093C}िंदगी", "ziṁdagī"), ("\u{095B}िंदगी", "ziṁdagī"),
                          ("ਸਤਿ ਸ੍ਰੀ ਅਕਾਲ", "sati srī akāla"), ("ਪੰਜਾਬ", "paṁjāba"), ("ਥੱਕੀ", "thakkī"),
                          ("ਉਹ", "uha"), ("ਇੱਕ", "ikka"), ("ਮੇਰੇ ਦੋ", "mērē dō"),
                          ("வணக்கம்", "vaṇakkam"), ("தமிழ்", "tamiḻ"), ("எஃகு", "eḵku"), ("கொண்டு", "koṇṭu"),
                          ("ஓடு", "ōṭu"), ("ய\u{0BC7}\u{0BBE}மகேஷ", "yōmakēṣa"),
                          ("ආයුබෝවන්", "āyubōvan"), ("ශ්\u{200D}රී ලංකා", "śrī laṅkā"), ("අම්මා", "ammā"),
                          ("කැමති", "kæmati"), ("චන්ද්\u{200D}ර", "chandra"), ("ෂෝ", "shō"), ("ක\u{0DD9}\u{0DCF}", "ko"),
                          ("ඹ", "ḅa"), ("ෛ", "ĩ"),
                          ("ভালোবাসা", "bhālōbāsā"), ("আমার সোনার বাংলা", "āmāra sōnāra bāṁlā"), ("সঁপেছি", "sãpēchi"),
                          ("ব\u{09A1}\u{09BC}", "baṛa"), ("ব\u{09DC}", "baṛa"), ("উৎসব", "utsaba"), ("অসমৰ", "asamara"),
                          ("નમસ્તે", "namastē"), ("ગુજરાતી", "gujarātī"),
                          ("నమస్కారం", "namaskāraṁ"), ("తెలుగు", "telugu"), ("ప్రేమ", "prēma"),
                          ("ನಮಸ್ಕಾರ", "namaskāra"), ("ಕನ್ನಡ", "kannaḍa"), ("ಕ\u{0CC6}\u{0CD5}", "kē"),
                          ("നമസ്കാരം", "namaskāraṁ"), ("എന്റെ", "enṟe"), ("ഞാൻ", "ñān"), ("മലയാളം", "malayāḷaṁ"),
                          ("കണ്ണ്", "kaṇṇŭ"), ("കണ്ണ് നീ", "kaṇṇŭ nī"), ("പറഞ്ഞു\u{0D4D}", "paṟaññŭ"),
                          ("ന\u{0D4D}\u{200D}", "n")] {
        expectEqual(IndicRomanization.romanize(text), latin.precomposedStringWithCanonicalMapping,
                    "ISO 15919: \(text) → \(latin)")
    }
    expectEqual(IndicRomanization.romanize("सनम 123 love"), "sanama 123 love", "ISO 15919: 别的字符原样保留")

    // ---- 泰语 RTGS:联合国报告注 1、2、5 的例子 ----
    for (th, latin) in [("สง่า", "sa-nga"), ("สะอาด", "sa-at"), ("สำอาง", "sam-ang"),
                        ("ทำบ่อยๆ", "tham boi boi"), ("สามารถ", "samat"), ("พรหม", "phrom"), ("ธาตุ", "that"),
                        ("ปรารถนา", "pratthana"), ("รัตนา", "rattana"), ("อินทรธนู", "inthanu")] {
        expectEqual(ThaiRomanization.romanize(th), latin, "泰语 RTGS: \(th) → \(latin)")
    }
    expectEqual(ThaiRomanization.romanize("ขอจูบเธอต่อไปนาน ๆ"), "kho chup thoe to pai nan nan",
                "泰语: ๆ 隔着空格也把前一个词再读一遍")
    expectEqual(ThaiRomanization.romanize("จ\u{0E4D}\u{0E32}"), ThaiRomanization.romanize("จำ"),
                "泰语: 「ํ + า」拆写跟「ำ」读音一样")
    expectEqual(ThaiRomanization.romanize("คนดี 123 Love you"), "khon di 123 Love you", "泰语: 非泰文字符原样保留")
    // 词与词空格、复合词连写(ลูกเสือ luksuea,RTGS 写词规则的例子);词典把短语写成几个词的照分;词典不认识的词连写。
    for (th, latin) in [("ลูกเสือ", "luksuea"), ("หัวใจ", "huachai"), ("โลมา", "loma"), ("ไม่ต้อง", "mai tong"),
                        ("ตอนนี้", "tonni"), ("สามารถ", "samat"), ("ปรารถนา", "pratthana")] {
        expectEqual(ThaiRomanization.romanize(th), latin, "泰语分词: \(th) → \(latin)")
    }
    // 规则兜底按 Unicode 标量拼:元音、声调符号是组合字符,按 Character 切会跟辅音并成一个、一个模板都对不上。
    for (th, latin) in [("กลับ", "klap"), ("คน", "khon"), ("เรียน", "rian"), ("ใจ", "chai"), ("หมา", "ma"),
                        ("การ์ด", "kat"), ("จักร", "chak")] {
        expectEqual(ThaiRomanization.ruleOnly(th), latin, "泰语规则兜底: \(th) → \(latin)")
    }

    // ---- 接进读音:整首歌 / 一行 / 开关 ----
    func reading(_ lyrics: String, at ms: Int = 1000, scripts: RomanizationScripts = .default) -> String? {
        let engine = LyricsSyncEngine()
        engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", romanizationScripts: scripts)
        return engine.activeLine(atMs: ms)?.romanization
    }
    expectEqual(reading("[00:01.00]Ты танцуешь"), "Ty tancueš\u{02B9}", "接入: 俄语歌按 GOST 1983 现算")
    expectEqual(reading("[00:01.00]Ты танцуешь", scripts: RomanizationScripts.default.subtracting(.russian)), nil,
                "接入: 关掉俄语就不标")
    expectEqual(reading("[00:01.00]Чи прошепотів\n[00:02.00]щастя моє", at: 2000), "shchastia moie",
                "接入: 西里尔字母按整首歌认出的语言转(这一行自己分不出俄语还是乌克兰语)")
    expectEqual(reading("[00:01.00]我爱你\n[00:02.00]Привет мир", at: 2000, scripts: [.russian]), "Privet mir",
                "接入: 中文歌里的一句俄语按这一行自己认,归俄语开关")
    expectEqual(reading("[00:01.00]สะอาด"), "sa-at", "接入: 泰语歌按 RTGS 现算")
    expectEqual(reading("[00:01.00]Καλημέρα"), "Kaliméra", "接入: 希腊语歌按 ELOT 743 现算")
    expectEqual(reading("[00:01.00]नमस्ते"), "namastē", "接入: 天城文按 ISO 15919 现算")
    expectEqual(reading("[00:01.00]നമസ്കാരം"), "namaskāraṁ", "接入: 马拉雅拉姆文按 ISO 15919 现算")
    expectEqual(reading("[00:01.00]নমস্কার", scripts: [.hindi]), nil, "接入: 孟加拉文归孟加拉语开关,不归印地语")

    // 用系统 Any-Latin 跟 GOST 写法不同的词(Щука:ICU 给 Ŝuka),才看得出是不是先按标准转了。
    let mixed = Romanizer.lineReading("我爱你 Щука", songLooksJapanese: false, segments: []) ?? ""
    expectEqual(mixed.contains("wǒ ài nǐ") && mixed.contains("Ščuka"), true,
                "接入: 汉字行里夹的西里尔字母先按标准转,剩下的再走拼音:\(mixed)")
    let mixedThai = Romanizer.lineReading("我爱你 สะอาด", songLooksJapanese: false, segments: []) ?? ""
    expectEqual(mixedThai.contains("sa-at"), true, "接入: 汉字行里夹的泰文按 RTGS 转:\(mixedThai)")
    expectEqual(LyricsRomanization.romanizeLRC("[00:01.00]สะอาด\n[00:02.00]你好"),
                "[00:01.00]sa-at\n[00:02.00]nǐ hǎo", "整份罗马音: 泰文行按 RTGS,汉字行照常(预生成同口径)")

    expectEqual(Romanizer.songScript(of: "Ты танцуешь, будто сумасшедшая"), .russian, "整首: 俄语歌")
    expectEqual(Romanizer.songScript(of: "วันที่เขาอ่านเธอ"), .thai, "整首: 泰语歌")
    expectEqual(Romanizer.songScript(of: "Καλημέρα"), .greek, "整首: 希腊语歌")
    expectEqual(Romanizer.songScript(of: "Ошол күнү сенден"), .unsupportedCyrillic, "整首: 不支持的西里尔语言单独一档")
    expectEqual(reading("[00:01.00]Ошол күнү сенден уялганымдан\n[00:02.00]Сен менин жаным", at: 2000), nil,
                "接入: 整首是吉尔吉斯语时,没有独有字母的短行也不按俄语转")
    let jaCyrillic = Romanizer.lineReading("ロシア Щука", songLooksJapanese: true,
                                           segments: Romanizer.japaneseSegments("ロシア Щука")) ?? ""
    expectEqual(jaCyrillic.contains("Ščuka"), true, "接入: 日文行里夹的西里尔字母按标准转:\(jaCyrillic)")
    let jaThai = Romanizer.lineReading("ありがとう สะอาด", songLooksJapanese: true,
                                       segments: Romanizer.japaneseSegments("ありがとう สะอาด")) ?? ""
    expectEqual(jaThai.contains("sa-at"), true, "接入: 日文行里夹的泰文按 RTGS 转:\(jaThai)")

    // ---- 默认值与升级 ----
    expectEqual(RomanizationScripts.defaultScripts(chineseUI: true).isSuperset(of: .world), true,
                "默认: 中文界面新语言也全开")
    expectEqual(RomanizationScripts.defaultScripts(chineseUI: true).contains(.chinese), false,
                "默认: 中文界面照旧不标拼音")
    let japanese = RomanizationScripts.japanese.rawValue
    let indicAdded: RomanizationScripts = [.bengali, .gujarati, .telugu, .kannada, .malayalam]
    expectEqual(RomanizationScripts.addingNewLanguages(storedRaw: japanese, knownRaw: nil),
                RomanizationScripts.japanese.union(.world), "升级: 只认得日 / 韩 / 中的版本存的值,保留原来的选择、新语言一并打开")
    let knownBefore = RomanizationScripts.legacyKnown.union(RomanizationScripts.world.subtracting(indicAdded))
    expectEqual(RomanizationScripts.addingNewLanguages(storedRaw: japanese, knownRaw: knownBefore.rawValue),
                RomanizationScripts.japanese.union(indicAdded), "升级: 存值那时已认得、关着的语言不再打开,只开之后新加的")
    expectEqual(RomanizationScripts.addingNewLanguages(storedRaw: japanese, knownRaw: RomanizationScripts.known.rawValue),
                .japanese, "导入: 这一版导出的照原样(用户关掉的不再打开)")
    for script in LyricScript.allCases {
        if let option = script.option {
            expectEqual(RomanizationScripts.known.contains(option), true, "认得的语言: \(script) 的开关位在 known 里")
        }
    }

    // ---- 「这份歌词可能标出读音吗」 ----
    expectEqual(LyricsPreviewText.mayHaveRomanization("Привет", scripts: [.russian]), true, "可能有读音: 俄语开着")
    expectEqual(LyricsPreviewText.mayHaveRomanization("Привет", scripts: [.thai]), false, "可能有读音: 只开泰语")
    expectEqual(LyricsPreviewText.mayHaveRomanization("إنت حبيبي", scripts: .default), false,
                "可能有读音: 阿拉伯字母不现算")

    // ---- 源自带读音里没转的原文片段(10 章决策 54) ----
    func sourceReading(_ lyrics: String, roma: String, scripts: RomanizationScripts = .default,
                       cantonese: Bool = false, at ms: Int = 1000) -> String? {
        let engine = LyricsSyncEngine()
        engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: roma, lyricsYRC: "", romanizationScripts: scripts,
                    songIsCantonese: cantonese)
        return engine.activeLine(atMs: ms)?.romanization
    }
    let R = SourceReadingResidue.self
    expectEqual(R.patched("tsukame ! egai ta 梦 o") { $0 == "梦" ? "yume" : nil }, "tsukame ! egai ta yume o",
                "残留: 没转的汉字换成读音")
    expectEqual(R.patched("Shì huì 謊yán") { _ in "huǎng" }, "Shì huì huǎng yán", "残留: 紧贴字母的补一个空格")
    expectEqual(R.patched("zi you (zi you 自由)") { _ in "zì yóu" }, "zi you (zi you zi you)",
                "残留: 源那一行不标声调,补进去的也不标")
    expectEqual(R.patched("a 梦 b") { _ in nil }, "a 梦 b", "残留: 给不出读音的照原样")
    expectEqual(R.patched("a 梦 b") { _ in "梦x" }, "a 梦 b", "残留: 给回来的还带着原文就不换")
    expectEqual(R.patched("nǐ謊yán") { _ in "huǎng" }, "nǐ huǎng yán", "残留: 前后紧贴字母都补空格")
    expectEqual(R.patched("ī ya ー yahayaha") { _ in "x" }, "ī ya ー yahayaha", "残留: 单独的长音记号是源写的,不算")
    expectEqual(R.patched("habibi حبيبي") { _ in "x" }, "habibi حبيبي", "残留: 阿拉伯字母本地不现算,不算")
    expectEqual(R.patched("(എടാ മോനെ)") { $0 == "എടാ" ? "eṭā" : "mōne" }, "(eṭā mōne)", "残留: 印度系的元音符号跟着字母走")
    expectEqual(R.patched("a ラーメン b") { $0 == "ラーメン" ? "rāmen" : nil }, "a ramen b", "残留: 片段里的长音跟着片段走")

    let jaRoma = "[00:01.00]tsukame ! egai ta 梦 o\n[00:02.00]sora"
    expectEqual(sourceReading("[00:01.00]つかめ! 描いた夢を\n[00:02.00]空", roma: jaRoma), "tsukame ! egai ta yume o",
                "接入: 源读音里的简体字,原文显示的是修过的日文汉字,按原文分词读")
    expectEqual(sourceReading("[00:01.00]つかめ! 描いた梦を\n[00:02.00]空", roma: jaRoma), "tsukame ! egai ta yume o",
                "接入: 原文也是简体字,转繁体再读")
    expectEqual(sourceReading("[00:01.00]В очите ѝ тогава ще ме припознаеш",
                              roma: "[00:01.00]V ochite ѝ togava shte me pripoznaesh"),
                "V ochite i togava shte me pripoznaesh", "接入: 源读音里没转的西里尔字母按整首认出的语言补")
    expectEqual(sourceReading("[00:01.00]В очите ѝ тогава ще ме припознаеш",
                              roma: "[00:01.05]V ochite ѝ togava shte me pripoznaesh"),
                "V ochite i togava shte me pripoznaesh", "接入: 时间没对齐、按就近挂上的源读音同样补")
    let taLyrics = "[00:01.00]இசையாலே இன்ப நிலை காண வந்தாயோ (എടാ മോനെ)"
    let taRoma = "[00:01.00]icaiyālē iṉpa nilai kāṇa vantāyō (എടാ മോനെ)"
    expectEqual(sourceReading(taLyrics, roma: taRoma), "icaiyālē iṉpa nilai kāṇa vantāyō (eṭā mōne)",
                "接入: 泰米尔歌源读音里夹的马拉雅拉姆文补上")
    expectEqual(sourceReading(taLyrics, roma: taRoma, scripts: RomanizationScripts.default.subtracting(.malayalam)),
                taRoma.replacingOccurrences(of: "[00:01.00]", with: ""), "接入: 那种文字的开关关着就不补")
    expectEqual(sourceReading("[00:01.00]我哋一齊行", roma: "[00:01.00]ngo5 dei6 一 cai4 hang4", cantonese: true),
                "ngo5 dei6 一 cai4 hang4", "接入: 粤语歌的汉字不补(现算出来是普通话拼音)")

    // 分词器读不出的简体字按繁体读;古木基文、天城文没有带点写法的点不出字。
    expectEqual(sourceReading("[00:01.00]つかめ! 描いた梦を\n[00:02.00]空", roma: ""), "tsukame ! egai ta yume o",
                "现算: 日文歌里分词器读不出的简体字按繁体读")
    let unreadBoth = sourceReading("[00:01.00]僕们の歌を\n[00:02.00]空", roma: "")
    expectEqual(unreadBoth.map { $0.contains("们") && !$0.contains("們") }, true, "现算: 繁体也读不出就照原样留着")
    expectEqual(IndicRomanization.romanize("ਢਾਕੜ\u{0A3C}"), "ḍhākaṛa", "ISO 15919: 古木基文多余的点不出字")
    expectEqual(IndicRomanization.romanize("म\u{093C}"), "ma", "ISO 15919: 天城文多余的点不出字")
}

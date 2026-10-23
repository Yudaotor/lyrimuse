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
    expectEqual(cyr("объём", .russian), "ob\u{2033}ëm", "俄语: ъ 写双撇 ″、ё 写 ë")
    expectEqual(cyr("Съешь же ещё этих мягких французских булок", .russian),
                "S\u{2033}eš\u{2032} že eščë ètih mjagkih francuzskih bulok", "俄语: 全字母句逐字对表")

    // ---- 乌克兰语 2010 ----
    for (ua, latin) in [("Згорани", "Zghorany"), ("Розгон", "Rozghon"), ("Єнакієве", "Yenakiieve"),
                        ("Їжакевич", "Yizhakevych"), ("Йосипівка", "Yosypivka"), ("Стрий", "Stryi"),
                        ("Юрій", "Yurii"), ("Корюківка", "Koriukivka"), ("Яготин", "Yahotyn"),
                        ("Знам’янка", "Znamianka"), ("Гадяч", "Hadiach"), ("Щербухи", "Shcherbukhy")] {
        expectEqual(cyr(ua, .ukrainian), latin, "乌克兰语: \(ua) → \(latin)")
    }

    // ---- 保加利亚语 2009 ----
    for (bg, latin) in [("София", "Sofia"), ("Пловдив", "Plovdiv"), ("Търговище", "Targovishte"),
                        ("Илиянци", "Iliyantsi"), ("Ямбол", "Yambol"), ("Хасково", "Haskovo")] {
        expectEqual(cyr(bg, .bulgarian), latin, "保加利亚语: \(bg) → \(latin)")
    }

    // ---- 白俄罗斯语 2007 ----
    for (be, latin) in [("Беларусь", "Bielaruś"), ("Магілёў", "Mahilioŭ"), ("Віцебск", "Viciebsk"),
                        ("Гомель", "Homieĺ"), ("Брэст", "Brest"), ("Ельск", "Jeĺsk")] {
        expectEqual(cyr(be, .belarusian), latin, "白俄罗斯语: \(be) → \(latin)")
    }

    // ---- 塞尔维亚语、马其顿语 1977 ----
    expectEqual(cyr("Ђорђе Љубав Џеп", .serbian), "Đorđe Ljubav Džep", "塞尔维亚语: ђ љ џ")
    expectEqual(cyr("ЉУБАВ", .serbian), "LJUBAV", "塞尔维亚语: 整词大写时双字母也全大写")
    expectEqual(cyr("Ќесендре", .macedonian), "Kesendre", "马其顿语: ќ 在 е 前写 k(报告里的例子)")
    expectEqual(cyr("Плакенска Планина", .macedonian), "Plakenska Planina", "马其顿语: 报告里的例子")
    expectEqual(cyr("Ѓорѓи", .macedonian), "Đorgi", "马其顿语: ѓ 在 и 前写 g、其余写 đ")
    expectEqual(cyr("Ѕвезда", .macedonian), "Dzvezda", "马其顿语: ѕ → dz")

    // ---- 哈萨克语 ISO 9 ----
    expectEqual(cyr("Қазақстан", .kazakh), "K\u{0326}azak\u{0326}stan", "哈萨克语 ISO 9: қ → k̦")
    expectEqual(cyr("Сәлем", .kazakh), "Sa\u{030B}lem", "哈萨克语 ISO 9: ә → a̋")

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
    for (text, latin) in [("नमस्ते", "namaste"), ("संगीत", "saṁgīta"), ("हूँ", "hū̃"), ("क्या", "kyā"),
                          ("दिल", "dila"), ("मैं", "maiṁ"), ("ज\u{093C}िंदगी", "ziṁdagī"), ("\u{095B}िंदगी", "ziṁdagī"),
                          ("ਸਤਿ ਸ੍ਰੀ ਅਕਾਲ", "sati srī akāla"), ("ਪੰਜਾਬ", "paṃjāba"), ("ਥੱਕੀ", "thakkī"),
                          ("ਉਹ", "uha"), ("ਇੱਕ", "ikka"),
                          ("வணக்கம்", "vaṇakkam"), ("தமிழ்", "tamiḻ"), ("எஃகு", "eḵku"), ("கொண்டு", "koṇṭu"),
                          ("ஓடு", "ōṭu"),
                          ("ආයුබෝවන්", "āyubōvan"), ("ශ්\u{200D}රී ලංකා", "śrī laṁkā"), ("අම්මා", "ammā"),
                          ("කැමති", "kæmati")] {
        expectEqual(IndicRomanization.romanize(text), latin.precomposedStringWithCanonicalMapping,
                    "ISO 15919: \(text) → \(latin)")
    }
    expectEqual(IndicRomanization.romanize("सनम 123 love"), "sanama 123 love", "ISO 15919: 别的字符原样保留")

    // ---- 泰语 RTGS:联合国报告注 1、2、5 的例子 ----
    for (th, latin) in [("สง่า", "sa-nga"), ("บังอร", "bang-on"), ("สะอาด", "sa-at"), ("สำอาง", "sam-ang"),
                        ("ทำบ่อยๆ", "tham boi boi"), ("สามารถ", "samat"), ("พรหม", "phrom"), ("ธาตุ", "that"),
                        ("ปรารถนา", "pratthana"), ("รัตนา", "rattana"), ("อินทรธนู", "inthanu")] {
        expectEqual(ThaiRomanization.romanize(th), latin, "泰语 RTGS: \(th) → \(latin)")
    }
    expectEqual(ThaiRomanization.romanize("ขอจูบเธอต่อไปนาน ๆ"), "kho chup thoe to pai nan nan",
                "泰语: ๆ 隔着空格也把前一个词再读一遍")
    expectEqual(ThaiRomanization.romanize("จ\u{0E4D}\u{0E32}"), ThaiRomanization.romanize("จำ"),
                "泰语: 「ํ + า」拆写跟「ำ」读音一样")
    expectEqual(ThaiRomanization.romanize("คนดี 123 Love you"), "khondi 123 Love you", "泰语: 非泰文字符原样保留")
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
    expectEqual(reading("[00:01.00]Ты танцуешь"), "Ty tancueš\u{2032}", "接入: 俄语歌按 GOST 1983 现算")
    expectEqual(reading("[00:01.00]Ты танцуешь", scripts: RomanizationScripts.default.subtracting(.russian)), nil,
                "接入: 关掉俄语就不标")
    expectEqual(reading("[00:01.00]Чи прошепотів\n[00:02.00]щастя моє", at: 2000), "shchastia moie",
                "接入: 西里尔字母按整首歌认出的语言转(这一行自己分不出俄语还是乌克兰语)")
    expectEqual(reading("[00:01.00]我爱你\n[00:02.00]Привет мир", at: 2000, scripts: [.russian]), "Privet mir",
                "接入: 中文歌里的一句俄语按这一行自己认,归俄语开关")
    expectEqual(reading("[00:01.00]สะอาด"), "sa-at", "接入: 泰语歌按 RTGS 现算")
    expectEqual(reading("[00:01.00]Καλημέρα"), "Kaliméra", "接入: 希腊语歌按 ELOT 743 现算")
    expectEqual(reading("[00:01.00]नमस्ते"), "namaste", "接入: 天城文按 ISO 15919 现算")
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
    expectEqual(Romanizer.songScript(of: "Ошол күнү сенден"), .other, "整首: 不支持的西里尔语言归 other")

    // ---- 默认值与升级 ----
    expectEqual(RomanizationScripts.defaultScripts(chineseUI: true).isSuperset(of: .world), true,
                "默认: 中文界面新语言也全开")
    expectEqual(RomanizationScripts.defaultScripts(chineseUI: true).contains(.chinese), false,
                "默认: 中文界面照旧不标拼音")
    expectEqual(RomanizationScripts.addingWorldLanguages(storedRaw: RomanizationScripts.japanese.rawValue,
                                                         migrated: false),
                RomanizationScripts.japanese.union(.world), "升级: 手动改过的人保留原来的选择、新语言一并打开")
    expectEqual(RomanizationScripts.addingWorldLanguages(storedRaw: RomanizationScripts.japanese.rawValue,
                                                         migrated: true), nil, "升级: 只判一次")
    expectEqual(RomanizationScripts.addingWorldLanguages(storedRaw: nil, migrated: false), nil,
                "升级: 没落过盘的人默认值里本来就有")

    // ---- 「这份歌词可能标出读音吗」 ----
    expectEqual(LyricsPreviewText.mayHaveRomanization("Привет", scripts: [.russian]), true, "可能有读音: 俄语开着")
    expectEqual(LyricsPreviewText.mayHaveRomanization("Привет", scripts: [.thai]), false, "可能有读音: 只开泰语")
    expectEqual(LyricsPreviewText.mayHaveRomanization("إنت حبيبي", scripts: .default), false,
                "可能有读音: 阿拉伯字母不现算")
}

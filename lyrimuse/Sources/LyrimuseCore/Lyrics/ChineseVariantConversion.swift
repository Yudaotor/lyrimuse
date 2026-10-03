import Foundation

/// 歌词的简繁转换：按行抽出看得见的文字，整段交给 ICU 转一次，再在 ICU 的结果上按原文逐字修几类 ICU 写错的字，
/// 写回原位置。只由 `ChineseVariant.converted` 调用；规则、全库回放和刻意不收的写法见 08 章决策 35。
///
/// 「看得见的文字」：括号里只有数字、`,:.-` 和空格的时间标签（`[00:12.34]`、`[行始,行长]`、`(词始,词长,0)`、
/// `<00:12.34>`）不算，原样保留。逐字歌词的字被时间标签隔开，整串交给 ICU 时它认不出词组（「头」「发」各自转成
/// 「頭發」），所以要先连成一句再转。某一行转完 Unicode 标量数变了，那一行退回整行直接交给 ICU、不做纠正。
enum ChineseVariantConversion {
    /// 「繁体」：ICU `Simplified-Traditional` + 纠正。
    static func toTraditional(_ text: String) -> String {
        convert(text, transform: StringTransform("Simplified-Traditional"), fix: fixTraditional)
    }

    /// 「简体」：ICU `Traditional-Simplified` + 纠正（`HanVariants` 由调用方随后再过）。纠正只把 ICU 改掉的几个
    /// 规范简体字还原成原文、把 ICU 留下的两个繁体字形换掉，别的不动。
    static func toSimplified(_ text: String) -> String {
        convert(text, transform: StringTransform("Traditional-Simplified"), fix: fixSimplified)
    }

    private typealias Scalars = [Unicode.Scalar]

    private static func convert(_ text: String, transform: StringTransform,
                                fix: (Scalars, inout Scalars) -> Void) -> String {
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0) }
        let visible = lines.map(visibleIndices)
        let joined = lines.indices.map { n in
            String(String.UnicodeScalarView(visible[n].map { lines[n][$0] }))
        }.joined(separator: "\n")
        guard let converted = joined.applyingTransform(transform, reverse: false) else { return text }
        let convertedLines = converted.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { Array($0) }
        guard convertedLines.count == lines.count else {
            return text.applyingTransform(transform, reverse: false) ?? text
        }
        var result = String.UnicodeScalarView()
        for n in lines.indices {
            if n > 0 { result.append("\n") }
            let indices = visible[n]
            var line = lines[n]
            var output = convertedLines[n]
            guard output.count == indices.count else {
                let whole = String(String.UnicodeScalarView(line))
                result.append(contentsOf: (whole.applyingTransform(transform, reverse: false) ?? whole).unicodeScalars)
                continue
            }
            fix(indices.map { line[$0] }, &output)
            for (k, index) in indices.enumerated() { line[index] = output[k] }
            result.append(contentsOf: line)
        }
        return String(result)
    }

    private static let closingBracket: [Unicode.Scalar: Unicode.Scalar] = ["[": "]", "(": ")", "<": ">"]
    private static let timingPunctuation: Set<Unicode.Scalar> = [",", ":", ".", "-", " "]

    private static func visibleIndices(_ s: Scalars) -> [Int] {
        var result: [Int] = []
        var j = 0
        while j < s.count {
            if let close = closingBracket[s[j]], let end = timingTagEnd(s, openAt: j, close: close) {
                j = end + 1
                continue
            }
            result.append(j)
            j += 1
        }
        return result
    }

    /// s[openAt] 是开括号；到第一个对应的闭括号为止只有数字和时间标点（至少一个数字）时，返回闭括号的位置。
    private static func timingTagEnd(_ s: Scalars, openAt: Int, close: Unicode.Scalar) -> Int? {
        var sawDigit = false
        var k = openAt + 1
        while k < s.count {
            let c = s[k]
            if c == close { return sawDigit ? k : nil }
            if ("0"..."9").contains(c) {
                sawDigit = true
            } else if !timingPunctuation.contains(c) {
                return nil
            }
            k += 1
        }
        return nil
    }

    private static func occurrences(of word: Scalars, in s: Scalars) -> [Int] {
        guard !word.isEmpty, word.count <= s.count else { return [] }
        var result: [Int] = []
        for start in 0...(s.count - word.count) where s[start] == word[0] {
            var j = 1
            while j < word.count && s[start + j] == word[j] { j += 1 }
            if j == word.count { result.append(start) }
        }
        return result
    }

    // MARK: 繁体

    private static let li: Unicode.Scalar = "里"
    private static let liInside: Unicode.Scalar = "裡"
    private static let chen: Unicode.Scalar = "沉"
    private static let wan: Unicode.Scalar = "挽"
    private static let middleDot: Unicode.Scalar = "·"
    private static let sanFa: Scalars = Array("散发".unicodeScalars)
    private static let sanFaHairPrefix: Unicode.Scalar = "头"
    private static let faEmit: Unicode.Scalar = "發"

    private static func fixTraditional(_ s: Scalars, _ o: inout Scalars) {
        let n = s.count
        var keepLi = Set<Int>()
        for word in liKeepWords {
            for start in occurrences(of: word, in: s) {
                for (j, c) in word.enumerated() where c == li { keepLi.insert(start + j) }
            }
        }
        for i in 0..<n {
            let c = s[i]
            if c == li, o[i] == li, !keepLi.contains(i), i > 0, !numerals.contains(s[i - 1]),
               !(i + 1 < n && liKeepNext.contains(s[i + 1])),
               !s[max(0, i - 3)...min(n - 1, i + 3)].contains(middleDot) {
                o[i] = liInside
            } else if c == chen {
                o[i] = chen
            } else if c == wan, !(i + 1 < n && funeralNext.contains(s[i + 1])) {
                o[i] = wan
            }
        }
        for phrase in phrases {
            for start in occurrences(of: phrase.from, in: s) {
                let after = start + phrase.from.count
                if let blocked = phrase.notBefore, after < n, s[after] == blocked { continue }
                for (j, c) in phrase.to.enumerated() { o[start + j] = c }
            }
        }
        for start in occurrences(of: sanFa, in: s) where !(start > 0 && s[start - 1] == sanFaHairPrefix) {
            o[start + 1] = faEmit
        }
        for i in 0..<n {
            if let glyph = traditionalGlyphs[o[i]] { o[i] = glyph }
        }
    }

    /// 「里」前一个字是这些时是度量（千里、十里、半里），保留不转。
    private static let numerals = Set("0123456789〇一七万三两九二五兩八六几十千半四幾数數百萬零０１２３４５６７８９".unicodeScalars)
    /// 「里」后一个字是这些时多半是音译名（克里斯、莫里森、马里奥），保留不转。
    private static let liKeepNext = Set("亚克兰夫奥娜尔布拉斯昂曼森欧洛约达".unicodeScalars)
    /// 「挽」后一个字是这些时是丧葬义，照 ICU 写「輓」。
    private static let funeralNext = Set("幛歌联词诗辞额".unicodeScalars)
    /// ICU 产出的异体字形换成标准字形。
    private static let traditionalGlyphs: [Unicode.Scalar: Unicode.Scalar] = ["繮": "韁", "醖": "醞"]

    /// 「里」保留不转「裡」的写法（度量、固定词、音译名、拟声词）。只会让某处少转一个，不会改坏。
    private static let liKeepWords: [Scalars] = [
        "公里", "英里", "海里", "华里", "市里程", "里程", "故里", "邻里", "闾里", "里弄",
        "里巷", "里长", "七里香", "百里香", "十里洋场", "哈里路亚", "阿里巴巴", "拳王阿里", "西西里", "香格里拉",
        "底格里斯", "佛罗里达", "马德里", "卡尔加里", "加里", "哈里", "密苏里", "格雷戈里", "德米特里", "佩里",
        "霍里", "里根", "慢条斯里", "歇斯底里", "卡路里", "特内里费", "特里", "尤里", "阿里", "斯里",
        "荷里活", "噼里啪啦", "叽里咕噜", "叽里呱啦", "稀里哗啦", "埃里", "奥里", "峇里", "胡里山", "里見",
    ].map { Array($0.unicodeScalars) }

    private struct Phrase {
        let from: Scalars
        let to: Scalars
        /// 紧接着是这个字时是跨词误配（「悸动|荡漾」「晃|晃荡荡」），不改。
        let notBefore: Unicode.Scalar?
    }

    private static let notBefore: [String: Unicode.Scalar] = ["动荡": "漾", "晃荡": "荡"]

    /// 原文（简体）→ 繁体，等长，命中处逐字覆盖 ICU 的结果。每一条都在全库里看过实际命中的上下文；
    /// 加一条之前先看它在全库里的所有命中，会跨词误配的不收（「关系紧密」里的「系紧」、「一笔划算」里的「笔划」）。
    private static let phrases: [Phrase] = [
        ("想象", "想像"), ("重复", "重複"), ("复眼", "複眼"), ("反复", "反覆"), ("答复", "答覆"), ("奇迹", "奇蹟"),
        ("事迹", "事蹟"), ("神迹", "神蹟"), ("苏醒", "甦醒"), ("复苏", "復甦"), ("尽量", "儘量"), ("尽快", "儘快"),
        ("尽早", "儘早"), ("尽可", "儘可"), ("尽速", "儘速"), ("愈合", "癒合"), ("痊愈", "痊癒"), ("裙摆", "裙襬"),
        ("衣摆", "衣襬"), ("下摆", "下襬"), ("发丝", "髮絲"), ("发梢", "髮梢"), ("发间", "髮間"), ("发辫", "髮辮"),
        ("发色", "髮色"), ("发尾", "髮尾"), ("发夹", "髮夾"), ("发髻", "髮髻"), ("发线", "髮線"), ("发根", "髮根"),
        ("发际", "髮際"), ("发型", "髮型"), ("秀发", "秀髮"), ("短发", "短髮"), ("金发", "金髮"), ("银发", "銀髮"),
        ("华发", "華髮"), ("植发", "植髮"), ("染发", "染髮"), ("烫发", "燙髮"), ("剪发", "剪髮"), ("毛发", "毛髮"),
        ("鬓发", "鬢髮"), ("松开", "鬆開"), ("松手", "鬆手"), ("松懈", "鬆懈"), ("松口", "鬆口"), ("松脱", "鬆脫"),
        ("松解", "鬆解"), ("松绑", "鬆綁"), ("松弛", "鬆弛"), ("松散", "鬆散"), ("松软", "鬆軟"), ("松垮", "鬆垮"),
        ("松了", "鬆了"), ("一松", "一鬆"), ("蓬松", "蓬鬆"), ("稀松", "稀鬆"), ("宽松", "寬鬆"), ("松松", "鬆鬆"),
        ("松动", "鬆動"), ("松饼", "鬆餅"), ("钟意", "鍾意"), ("钟情", "鍾情"), ("钟爱", "鍾愛"), ("刮风", "颳風"),
        ("风刮", "風颳"), ("刮起风", "颳起風"), ("刮大风", "颳大風"), ("跟斗", "跟斗"), ("筋斗", "筋斗"), ("烟斗", "煙斗"),
        ("斗篷", "斗篷"), ("斗转", "斗轉"), ("斗酒", "斗酒"), ("斗大", "斗大"), ("反斗", "反斗"), ("漏斗", "漏斗"),
        ("熨斗", "熨斗"), ("斗笠", "斗笠"), ("星斗", "星斗"), ("倒斗", "倒斗"), ("系上", "繫上"), ("系住", "繫住"),
        ("心系", "心繫"), ("牵系", "牽繫"), ("维系", "維繫"), ("书签", "書籤"), ("便签", "便籤"), ("标签", "標籤"),
        ("抽签", "抽籤"), ("牙签", "牙籤"), ("价签", "價籤"), ("泡面", "泡麵"), ("吃面", "吃麵"), ("牛肉面", "牛肉麵"),
        ("拉面", "拉麵"), ("杯面", "杯麵"), ("意面", "意麵"), ("面店", "麵店"), ("面馆", "麵館"), ("碗面", "碗麵"),
        ("汤面", "湯麵"), ("炒面", "炒麵"), ("凉面", "涼麵"), ("挂面", "掛麵"), ("王子面", "王子麵"), ("面粉", "麵粉"),
        ("煮面", "煮麵"), ("冲走", "沖走"), ("冲刷", "沖刷"), ("冲掉", "沖掉"), ("冲澡", "沖澡"), ("冲泡", "沖泡"),
        ("冲印", "沖印"), ("冲洗", "沖洗"), ("冲淡", "沖淡"), ("冲凉", "沖涼"), ("余温", "餘溫"), ("余味", "餘味"),
        ("余光", "餘光"), ("余晖", "餘暉"), ("之余", "之餘"), ("余下", "餘下"), ("余韵", "餘韻"), ("余响", "餘響"),
        ("余情", "餘情"), ("无余", "無餘"), ("只余", "只餘"), ("唯余", "唯餘"), ("空余", "空餘"), ("余烟", "餘煙"),
        ("富余", "富餘"), ("厨余", "廚餘"), ("余音", "餘音"), ("残余", "殘餘"), ("其余", "其餘"), ("剩余", "剩餘"),
        ("余生", "餘生"), ("轮回", "輪迴"), ("回响", "迴響"), ("回荡", "迴盪"), ("回避", "迴避"), ("回旋", "迴旋"),
        ("动荡", "動盪"), ("摇荡", "搖盪"), ("震荡", "震盪"), ("激荡", "激盪"), ("涤荡", "滌盪"), ("晃荡", "晃盪"),
        ("摆荡", "擺盪"), ("密布", "密佈"), ("布满", "佈滿"), ("遍布", "遍佈"), ("摆布", "擺佈"), ("散布", "散佈"),
        ("颁布", "頒佈"), ("分布", "分佈"), ("宣布", "宣佈"), ("公布", "公佈"), ("布局", "佈局"), ("瞄准", "瞄準"),
        ("精准", "精準"), ("对准", "對準"), ("看准", "看準"), ("找准", "找準"), ("准则", "準則"), ("准心", "準心"),
        ("准星", "準星"), ("准点", "準點"), ("准时", "準時"), ("准确", "準確"), ("准是", "準是"), ("准没", "準沒"),
        ("划过", "劃過"), ("划破", "劃破"), ("划落", "劃落"), ("企划", "企劃"), ("刻划", "刻劃"), ("勾划", "勾劃"),
        ("划燃", "劃燃"), ("划花", "劃花"), ("划穿", "劃穿"), ("划上", "劃上"), ("划下", "劃下"), ("划伤", "劃傷"),
        ("划开", "劃開"), ("影后", "影后"), ("歌后", "歌后"), ("埃及艳后", "埃及艷后"), ("蜂后", "蜂后"), ("母后", "母后"),
        ("后羿", "后羿"), ("游刃", "遊刃"), ("吟游", "吟遊"), ("唱游", "唱遊"), ("园游会", "園遊會"), ("重游", "重遊"),
        ("漫游", "漫遊"), ("周游", "周遊"), ("神游", "神遊"), ("游历", "遊歷"), ("游子", "遊子"), ("游客", "遊客"),
        ("游乐", "遊樂"), ("游行", "遊行"), ("云游", "雲遊"),
    ].map { pair in
        Phrase(from: Array(pair.0.unicodeScalars), to: Array(pair.1.unicodeScalars), notBefore: notBefore[pair.0])
    }

    // MARK: 简体

    private static func fixSimplified(_ s: Scalars, _ o: inout Scalars) {
        for i in s.indices where simplifiedKeepAlways.contains(s[i]) { o[i] = s[i] }
        for word in simplifiedKeepWords {
            for start in occurrences(of: word, in: s) {
                for (j, c) in word.enumerated() where simplifiedRestorable.contains(c) { o[start + j] = c }
            }
        }
        for i in o.indices {
            if let glyph = simplifiedGlyphs[o[i]] { o[i] = glyph }
        }
    }

    /// 这几个字本身就是规范简体字，ICU 却会改掉（「俱」→「具」），一律原样。
    private static let simplifiedKeepAlways = Set("俱像囍氹跤".unicodeScalars)
    /// ICU 在个别词组里会留下这两个繁体字形（「內裡」「生旦淨末丑」），换成简体。
    private static let simplifiedGlyphs: [Unicode.Scalar: Unicode.Scalar] = ["內": "内", "淨": "净"]
    /// 这几个字只在下面这些词里原样，别处照 ICU 转（「藉口」→「借口」、「瞭解」→「了解」）。
    private static let simplifiedRestorable = Set("藉瞭乾徵".unicodeScalars)
    private static let simplifiedKeepWords: [Scalars] = [
        "慰藉", "狼藉", "枕藉", "蕴藉", "蘊藉", "藉藉", "瞭望", "乾隆",
        "乾坤", "乾卦", "乾陵", "角徵羽", "宫商角徵羽", "宮商角徵羽",
    ].map { Array($0.unicodeScalars) }
}

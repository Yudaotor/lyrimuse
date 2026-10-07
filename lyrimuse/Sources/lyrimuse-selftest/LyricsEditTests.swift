import Foundation
import LyrimuseCore

// 逐字歌词只改字(LyricsWordTimingEdit):摊开的文本、套回逐字、整行歌词跟着改、只改字的判定。
func runLyricsEditTests() {
    let yrc = """
    [ti:一个人一支灯]
    [ar:薛凯琪]
    [0,2280](0,126,0)一(126,126,0)个(252,126,0)人(378,126,0)一(504,126,0)支(630,252,0)灯 (882,252,0)- (1134,126,0)薛(1260,126,0)凯(1386,252,0)琪
    [2280,2290](2280,458,0)词(2738,458,0)：(3196,458,0)周(3654,458,0)耀(4112,458,0)辉
    [6860,4079](6860,270,0)我(7130,360,0)想(7490,370,0)记(7860,1230,0)得 (9090,350,0)这(9440,789,0)肉(10229,710,0)身
    [11000,3000](11000,1000,0)第(12000,1000,0)二(13000,1000,0)句
    """
    let lrc = """
    [ti:一个人一支灯]
    [00:00.00]一个人一支灯 - 薛凯琪 (Fiona Sit)
    [00:02.28]词：周耀辉
    [00:06.86]我想记得 这肉身
    [00:11.00]第二句
    """
    let view = LyricsWordTimingEdit.editableText(yrc: yrc)
    expectEqual(view, """
    [00:00.00]一个人一支灯 - 薛凯琪
    [00:02.28]词：周耀辉
    [00:06.86]我想记得 这肉身
    [00:11.00]第二句
    """, "只改字: 摊开的是逐字拼出来的每一行,行首是这一行的起点")
    expectEqual(LyricsWordTimingEdit.hasWordLines(yrc) && !LyricsWordTimingEdit.hasWordLines("[ti:x]\n[ar:y]")
                && !LyricsWordTimingEdit.hasWordLines(""), true, "只改字: 有没有能摊开的逐字行")

    func edited(_ from: String, _ to: String) -> String {
        let out = view.replacingOccurrences(of: from, with: to)
        precondition(out != view, "样例没改到: \(from)")
        return out
    }
    func line(_ yrc: String, at ms: Int) -> String? {
        yrc.components(separatedBy: "\n").first { $0.hasPrefix("[\(ms),") }
    }

    let same = LyricsWordTimingEdit.apply(edited: view, yrc: yrc, lrc: lrc)
    expectEqual(same.yrc == yrc && same.lrc == lrc && same.changedLines == 0 && same.timingUnchanged, true,
                "只改字: 没改就两份原样")

    // 改错字:词的时间一个不动,只换字
    let typo = LyricsWordTimingEdit.apply(edited: edited("我想记得", "我想忘得"), yrc: yrc, lrc: lrc)
    expectEqual(line(typo.yrc, at: 6860), "[6860,4079](6860,270,0)我(7130,360,0)想(7490,370,0)忘(7860,1230,0)得 (9090,350,0)这(9440,789,0)肉(10229,710,0)身",
                "只改字: 改一个字,其余词原样、时间不动")
    expectEqual(typo.yrc.components(separatedBy: "\n").filter { !$0.hasPrefix("[6860,") },
                yrc.components(separatedBy: "\n").filter { !$0.hasPrefix("[6860,") }, "只改字: 没改的行逐字节原样")
    expectEqual(typo.changedLines == 1 && typo.estimatedLines == 0 && typo.removedLines == 0 && typo.timingUnchanged, true,
                "只改字: 改字算一行改动、时间轴没动")
    expectEqual(typo.lrc.contains("[00:06.86]我想忘得 这肉身\n") && !typo.lrc.contains("记得"), true,
                "只改字: 整行歌词里对得上的那行跟着换字")

    // 插字并进前一个字所在的词,删字把那个词去掉
    let insert = LyricsWordTimingEdit.apply(edited: edited("我想记得", "我想要记得"), yrc: yrc, lrc: lrc)
    expectEqual(line(insert.yrc, at: 6860), "[6860,4079](6860,270,0)我(7130,360,0)想要(7490,370,0)记(7860,1230,0)得 (9090,350,0)这(9440,789,0)肉(10229,710,0)身",
                "只改字: 插进来的字并进前一个字所在的词")
    let delete = LyricsWordTimingEdit.apply(edited: edited("我想记得", "我想得"), yrc: yrc, lrc: lrc)
    expectEqual(line(delete.yrc, at: 6860), "[6860,4079](6860,270,0)我(7130,360,0)想(7860,1230,0)得 (9090,350,0)这(9440,789,0)肉(10229,710,0)身",
                "只改字: 删掉的字所在的词没字了就去掉")
    let punct = LyricsWordTimingEdit.apply(edited: edited("记得 这", "记得，这"), yrc: yrc, lrc: lrc)
    expectEqual(line(punct.yrc, at: 6860), "[6860,4079](6860,270,0)我(7130,360,0)想(7490,370,0)记(7860,1230,0)得，(9090,350,0)这(9440,789,0)肉(10229,710,0)身",
                "只改字: 只换标点也换进原来那个词")

    // 整行重写:新字按原来几个词的字数比例分回去,时间还是原来那几个词的
    let rewrite = LyricsWordTimingEdit.apply(edited: edited("[00:11.00]第二句", "[00:11.00]完全不同的话"), yrc: yrc, lrc: lrc)
    expectEqual(line(rewrite.yrc, at: 11000), "[11000,3000](11000,1000,0)完全(12000,1000,0)不同(13000,1000,0)的话",
                "只改字: 整行重写按原来每个词的字数比例分,时间照旧")
    let kept = LyricsWordTimingEdit.apply(edited: edited("[00:11.00]第二句", "[00:11.00]这是新的一句"), yrc: yrc, lrc: lrc)
    expectEqual(line(kept.yrc, at: 11000), "[11000,3000](11000,1000,0)这是新(12000,1000,0)的一(13000,1000,0)句",
                "只改字: 没改的字留在原来的词里,换掉的那段分给被换掉的词")
    expectEqual(rewrite.timingUnchanged, true, "只改字: 整行重写也只是改字")

    // 拉丁词:改拼写不拆词,插进来的词并进前一个词
    let latin = "[1000,2000](1000,500,0)Hello (1500,500,0)wrold"
    let fixed = LyricsWordTimingEdit.apply(edited: "[00:01.00]Hello world", yrc: latin, lrc: "")
    expectEqual(fixed.yrc, "[1000,2000](1000,500,0)Hello (1500,500,0)world", "只改字: 改拼写不拆开那个词")
    let added = LyricsWordTimingEdit.apply(edited: "[00:01.00]Hello big world", yrc: "[1000,2000](1000,500,0)Hello (1500,500,0)world", lrc: "")
    expectEqual(added.yrc, "[1000,2000](1000,500,0)Hello big (1500,500,0)world", "只改字: 插进来的词并进前一个词")
    let prefixed = LyricsWordTimingEdit.apply(edited: "[00:01.00]You're not there",
                                              yrc: "[1000,2000](1000,500,0)You're (1500,500,0)not (2000,500,0)here", lrc: "")
    expectEqual(prefixed.yrc, "[1000,2000](1000,500,0)You're (1500,500,0)not (2000,500,0)there",
                "只改字: 贴着后一个词开头插进来的字母并进后一个词")

    // 清空一行 = 删掉这一行;删行时整行歌词里对得上的那行跟着删
    let cleared = LyricsWordTimingEdit.apply(edited: edited("[00:11.00]第二句", "[00:11.00]  "), yrc: yrc, lrc: lrc)
    let dropped = LyricsWordTimingEdit.apply(edited: edited("\n[00:11.00]第二句", ""), yrc: yrc, lrc: lrc)
    expectEqual([cleared.yrc, dropped.yrc].allSatisfy { line($0, at: 11000) == nil } && cleared.removedLines == 1
                && dropped.removedLines == 1 && !dropped.timingUnchanged && !dropped.lrc.contains("第二句"), true,
                "只改字: 清空或删掉一行,逐字和整行歌词都删掉这一行,时间轴算动过")

    // 新加的行:按字数均分,不超过下一行开始;插在时间对得上的位置,整行歌词也插进去
    let appended = LyricsWordTimingEdit.apply(edited: view + "\n[00:15.00]第三句", yrc: yrc, lrc: lrc)
    expectEqual(appended.yrc.components(separatedBy: "\n").last, "[15000,1050](15000,350,0)第(15350,350,0)三(15700,350,0)句",
                "只改字: 新加的行按字数均分时长")
    expectEqual(appended.estimatedLines == 1 && !appended.timingUnchanged && appended.lrc.hasSuffix("[00:11.00]第二句\n[00:15.00]第三句"), true,
                "只改字: 新加的行算估出来的,整行歌词按时间插进去")
    let middle = LyricsWordTimingEdit.apply(edited: edited("[00:06.86]", "[00:05.00]插入\n[00:06.86]"), yrc: yrc, lrc: lrc)
    let middleLines = middle.yrc.components(separatedBy: "\n")
    expectEqual(middleLines.firstIndex(of: "[5000,800](5000,400,0)插(5400,400,0)入").map { middleLines[$0 + 1].hasPrefix("[6860,") }, true,
                "只改字: 中间插一行,时长不超过下一行开始,位置按时间排")

    let capped = LyricsWordTimingEdit.apply(edited: edited("[00:11.00]", "[00:10.50]很长的一句歌词\n[00:11.00]"), yrc: yrc, lrc: lrc)
    expectEqual(line(capped.yrc, at: 10500)?.hasPrefix("[10500,500](10500,71,0)很"), true,
                "只改字: 新加的行时长不超过下一行开始")
    let latinLine = LyricsWordTimingEdit.apply(edited: view + "\n[00:15.00]Hello world", yrc: yrc, lrc: lrc)
    expectEqual(latinLine.yrc.components(separatedBy: "\n").last, "[15000,800](15000,400,0)Hello (15400,400,0)world",
                "只改字: 新加的拉丁行按词分,不拆字母")

    // 副歌重复:改后一次,整行歌词里只换时间对得上的那一句,前面那句一样的不动
    let chorusYRC = yrc + "\n[60000,4079](60000,270,0)我(60270,360,0)想(60630,370,0)记(61000,1230,0)得 (62230,350,0)这(62580,789,0)肉(63369,710,0)身"
    let chorusLRC = lrc + "\n[01:00.00]我想记得 这肉身"
    let chorusEdit = LyricsWordTimingEdit.editableText(yrc: chorusYRC).replacingOccurrences(of: "[01:00.00]我想记得", with: "[01:00.00]我想忘得")
    let chorus = LyricsWordTimingEdit.apply(edited: chorusEdit, yrc: chorusYRC, lrc: chorusLRC).lrc
    expectEqual(chorus.contains("[00:06.86]我想记得 这肉身") && chorus.hasSuffix("[01:00.00]我想忘得 这肉身"), true,
                "只改字: 整行歌词里只换时间对得上的那一句,重复的副歌不动")

    // 改了时间戳的行:原来那行删掉,按新时间重新估
    let moved = LyricsWordTimingEdit.apply(edited: edited("[00:11.00]第二句", "[00:11.50]第二句"), yrc: yrc, lrc: lrc)
    expectEqual(moved.removedLines == 1 && moved.estimatedLines == 1 && line(moved.yrc, at: 11000) == nil
                && line(moved.yrc, at: 11500) != nil && moved.lrc.contains("[00:11.50]第二句") && !moved.lrc.contains("[00:11.00]"), true,
                "只改字: 改了时间戳按新时间重新估,整行歌词跟着挪")

    // 没有时间戳的行不进逐字
    let untimed = LyricsWordTimingEdit.apply(edited: view + "\n随手写的一行", yrc: yrc, lrc: lrc)
    expectEqual(untimed.yrc == yrc && untimed.skippedLines == 1, true, "只改字: 没有时间戳的行不进逐字")

    // 整行歌词跟逐字对不上(网易云那种)就不动
    let other = "[00:06.80]我想记得这个肉身啊\n[00:11.00]第二句"
    expectEqual(LyricsWordTimingEdit.apply(edited: edited("我想记得", "我想忘得"), yrc: yrc, lrc: other).lrc, other,
                "只改字: 整行歌词对不上的行不动")

    // CRLF:没改的行原样,改过的行跟着用 CRLF
    let crlf = yrc.replacingOccurrences(of: "\n", with: "\r\n")
    let crlfTypo = LyricsWordTimingEdit.apply(edited: edited("我想记得", "我想忘得"), yrc: crlf, lrc: "")
    expectEqual(crlfTypo.yrc, typo.yrc.replacingOccurrences(of: "\n", with: "\r\n"), "只改字: CRLF 的逐字改完还是 CRLF")

    // 编辑框摘掉的署名行拼回去之后原样(位置挪到后面也认得)
    let body = LyricsBodyEdit(lyrics: view, title: "一个人一支灯", artist: "薛凯琪")
    let viaBody = LyricsWordTimingEdit.apply(edited: body.reassembled(body: body.body.replacingOccurrences(of: "我想记得", with: "我想忘得")),
                                             yrc: yrc, lrc: lrc)
    expectEqual(!body.body.contains("词：") && viaBody.yrc == typo.yrc, true, "只改字: 编辑框摘掉的署名行原样留在逐字里")

    expectEqual(LyricsWordTimingEdit.sameLineTimes("[00:01.00]a\n[00:02.00]b", "[00:01.00]甲\n[00:02.00]乙")
                && !LyricsWordTimingEdit.sameLineTimes("[00:01.00]a\n[00:02.00]b", "[00:01.00]a\n[00:02.50]b"), true,
                "只改字: 整行歌词时间戳没动才算只改字")

    // 文件头标签(外部编辑器摊开的工作副本开头就有)不算没时间戳的行
    let tagged = LyricsWordTimingEdit.apply(edited: "[ti:一个人一支灯]\n[offset:0]\n\n" + view, yrc: yrc, lrc: lrc)
    expectEqual(tagged.skippedLines == 0 && tagged.yrc == yrc && tagged.lrc == lrc, true, "只改字: [ti:] 这类文件头不算没时间戳的行")

    // 行尾空白不算改过(编辑器存盘时常顺手删掉):只差行尾空格的行原样留着,连那个空格;真改了字的行照常算改动
    let spaced = "[1000,2000](1000,1000,0)Hello (2000,1000,0)world \n[4000,2000](4000,1000,0)second (5000,1000,0)line"
    expectEqual(LyricsWordTimingEdit.editableText(yrc: spaced), "[00:01.00]Hello world \n[00:04.00]second line",
                "只改字: 行尾的空格照样摊开")
    let trimmedSave = LyricsWordTimingEdit.apply(edited: "[00:01.00]Hello world\n[00:04.00]second line\n", yrc: spaced, lrc: "")
    expectEqual(trimmedSave.yrc == spaced && trimmedSave.changedLines + trimmedSave.estimatedLines + trimmedSave.removedLines == 0,
                true, "只改字: 只删了行尾空格、补了末尾换行,不算改动")
    let editedBeside = LyricsWordTimingEdit.apply(edited: "[00:01.00]Hello world\n[00:04.00]2nd line\n", yrc: spaced, lrc: "")
    expectEqual(editedBeside.changedLines == 1 && editedBeside.yrc.hasPrefix("[1000,2000](1000,1000,0)Hello (2000,1000,0)world \n"),
                true, "只改字: 改了别的行时,只差行尾空格的那一行原样留着")

    runLyricsExternalEditTests(yrc: yrc, lrc: lrc)
}

// 歌词窗口「用外部编辑器改歌词」(LyricsExternalEdit,07 章决策 112):摊开什么、存回来怎么套、盘上已有的工作副本能不能盖,
// 以及歌词窗口、外部编辑器这两头的接法。
func runLyricsExternalEditTests(yrc: String, lrc: String) {
    typealias E = LyricsExternalEdit
    let word = E.Content(lyrics: lrc, yrc: yrc)
    let line = E.Content(lyrics: "[ti:x]\n[00:01.00]第一句\n[00:02.00]第二句\n")
    let plain = E.Content(plain: "第一句\n第二句")
    let none = E.Content()
    expectEqual([E.mode(of: word), E.mode(of: line), E.mode(of: plain), E.mode(of: none),
                 E.mode(of: E.Content(lyrics: lrc, yrc: "[ti:x]")), E.mode(of: E.Content(lyrics: lrc, plain: "第一句"))],
                [.wordTimed, .lineTimed, .plainText, .empty, .lineTimed, .lineTimed],
                "外部编辑: 有逐字行按逐字,有整行歌词按整行(纯文本兜底也在时同样),只有纯文本按纯文本,都没有按空的")

    let copy = E.workingCopy(word, title: "一个人一支灯", artist: "薛凯琪", album: "")
    expectEqual(copy, "[ti:一个人一支灯]\n[ar:薛凯琪]\n\n" + LyricsWordTimingEdit.editableText(yrc: yrc) + "\n",
                "外部编辑: 逐字摊开逐字拼出来的每一行,前面是文件头,空的那项不写")
    expectEqual(E.workingCopy(line, title: "t", artist: "a", album: "al"), line.lyrics, "外部编辑: 整行歌词原样摊开")
    expectEqual(E.workingCopy(none, title: "t", artist: "a\nb", album: "al"), "[ti:t]\n[ar:a b]\n[al:al]\n\n",
                "外部编辑: 没有歌词只有文件头(换行压成空格)")
    expectEqual(E.workingCopy(plain, title: "t", artist: "", album: ""), "[ti:t]\n\n第一句\n第二句\n",
                "外部编辑: 纯文本前面带文件头")

    expectEqual([E.decide(edited: copy, base: word), E.decide(edited: line.lyrics, base: line),
                 E.decide(edited: E.workingCopy(plain, title: "t", artist: "a", album: ""), base: plain)],
                [.unchanged, .unchanged, .unchanged], "外部编辑: 原样存回来不用存")
    expectEqual([E.decide(edited: "", base: word), E.decide(edited: "[ti:x]\n[ar:y]\n\n", base: none),
                 E.decide(edited: "[00:01.00]\n\n", base: line), E.decide(edited: " \n\t\n", base: plain)],
                [.empty, .empty, .empty, .empty], "外部编辑: 空文件、只剩文件头或空时间戳都不算录入了歌词")

    if case let .word(r) = E.decide(edited: copy.replacingOccurrences(of: "我想记得", with: "我想忘得"), base: word) {
        expectEqual(r.changedLines == 1 && r.skippedLines == 0 && r.timingUnchanged && r.yrc.contains("(7490,370,0)忘")
                    && r.lrc.contains("[00:06.86]我想忘得 这肉身"), true,
                    "外部编辑: 逐字改字套回逐字,文件头不算没时间戳的行")
    } else {
        expectEqual(true, false, "外部编辑: 逐字改字应当套回逐字")
    }
    expectEqual(E.decide(edited: "[ti:x]\n随手一句\n另一句", base: word), .missingTimestamps,
                "外部编辑: 逐字整份换成没有时间戳的文本不存")
    expectEqual(E.decide(edited: "[00:01.00]改了\n[00:02.00]第二句", base: line), .lines("[00:01.00]改了\n[00:02.00]第二句"),
                "外部编辑: 整行歌词整份换成存回来的这一份")
    expectEqual(E.decide(edited: "第一句\n第二句", base: line), .missingTimestamps,
                "外部编辑: 整行歌词去掉了全部时间戳不存")
    expectEqual(E.decide(edited: "第一句", base: E.Content(lyrics: "没有时间戳的一行")), .lines("第一句"),
                "外部编辑: 原来就没有时间戳的整行歌词照存")
    expectEqual(E.decide(edited: "[ti:t]\n\n[00:01.00]新的一句\n", base: none), .lines("[ti:t]\n\n[00:01.00]新的一句\n"),
                "外部编辑: 原来没有歌词,带时间戳的存成歌词")
    expectEqual(E.decide(edited: "[ti:t]\n[ar:a]\n\n第一句\n\n第二句\n\n", base: none), .plain("第一句\n\n第二句"),
                "外部编辑: 不带时间戳的存成纯文本,去掉开头的文件头和头尾空行,中间的空行留着")
    expectEqual(E.decide(edited: "[Intro: 某人]\n第一句", base: plain), .plain("[Intro: 某人]\n第一句"),
                "外部编辑: 不是文件头的方括号行留着")
    expectEqual(E.decide(edited: "第一句\r\n第二句\r\n", base: none), .plain("第一句\n第二句"), "外部编辑: 纯文本行尾的 \\r 去掉")

    // 编辑器存盘时补上末尾的换行、删掉行尾空格(Vim、Zed 默认都这样):不算改过,不然什么都没动也会存成人工修正、锁住
    let noFinalNewline = E.Content(lyrics: "[00:01.00]第一句 \n[00:02.00]第二句")
    expectEqual([E.decide(edited: "[00:01.00]第一句\n[00:02.00]第二句\n", base: noFinalNewline),
                 E.decide(edited: "[ti:t]\n\n第一句  \n第二句\n\n", base: plain)],
                [.unchanged, .unchanged], "外部编辑: 只补了末尾换行、删了行尾空格不算改过")
    expectEqual(E.decide(edited: "[00:01.00]第一句\n[00:02.00]第二句改\n", base: noFinalNewline),
                .lines("[00:01.00]第一句\n[00:02.00]第二句改\n"), "外部编辑: 真改了字照存")

    expectEqual([E.fileAction(existing: nil, fresh: "a", recorded: nil),
                 E.fileAction(existing: "a", fresh: "a", recorded: nil),
                 E.fileAction(existing: "old", fresh: "a", recorded: E.fingerprint("old")),
                 E.fileAction(existing: "edited", fresh: "a", recorded: E.fingerprint("old")),
                 E.fileAction(existing: "edited", fresh: "a", recorded: nil)],
                [.write, .reuse, .write, .setAsideThenWrite, .setAsideThenWrite],
                "外部编辑: 盘上那份是写进去 / 套用过的才覆盖,别的先挪开")

    expectEqual(E.text(from: Data([0xEF, 0xBB, 0xBF] + Array("歌".utf8))), "歌", "外部编辑: UTF-8 开头的 BOM 去掉")
    expectEqual(E.text(from: "歌词\n".data(using: .utf16) ?? Data()), "歌词\n", "外部编辑: 带 BOM 的 UTF-16 也认")
    expectEqual(E.text(from: Data([0xC3, 0x28])), nil, "外部编辑: 不是 UTF-8 的读不出")

    // 接法:三颗图标只有图标、带悬停提示和辅助功能名称;重新匹配跟歌词管理同一个 runner、要先确认的先确认;
    // 外部编辑套回去之前等读取器解到盘上那一版、核对正文没变,存走改动通道,不碰引擎导出的歌词目录。
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func read(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
    let window = read("lyrimuse/UI/LyricsWindowView.swift")
    expectEqual(window.contains("LyricsWindowActionsCapsule(onArtwork: hasArtworkBackground, enabled: !lyricsOnHold,")
                && window.contains("LyricsWindowActionCaption(currentTitle: playback.title, onArtwork: hasArtworkBackground)"), true,
                "外部编辑(接法): 歌词窗口右下摆三颗图标和上方的说明条,广告 / 串场时置灰")
    let actions = read("lyrimuse/UI/LyricsWindowActions.swift")
    expectEqual(actions.components(separatedBy: ".help(label)\n        .accessibilityLabel(label)").count - 1 == 3
                && actions.contains("LyricsRematchRunner.run(key: key, id: id, isCurrent: { round?.id == id })")
                && actions.contains("if stored.manualLyrics {") && actions.contains("if stored.instrumental {")
                && actions.contains("} else if playback.trackLyricsOffsetMs != 0 {"), true,
                "外部编辑(接法): 图标带悬停提示和辅助功能名称;重新匹配走同一个 runner,手改 / 纯音乐 / 校准过的先确认")
    let runner = read("lyrimuse/LyricsManager/LyricsRematchRunner.swift")
    expectEqual(runner.contains("do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return nil }")
                && !runner.contains("try? await Task.sleep"), true,
                "重新匹配(接法): 等结论时任务被取消就返回,不吞掉取消、在主线程上空转")
    expectEqual(actions.contains("Image(systemName: \"chevron.up\")")
                && actions.contains("if menu.isOpen {\n                menuPanel")
                && actions.contains("Button(\"\", action: openEditor)\n                .keyboardShortcut(\"e\", modifiers: .command)")
                && actions.contains(".padding(.bottom, menu.isOpen ? 44 : 0)"), true,
                "外部编辑(接法): 第三格是箭头,指针停上去或点一下往上弹出放着手动编辑的小菜单,说明条让开;⌘E 不用打开菜单也能用")
    let editor = read("lyrimuse/LyricsManager/LyricsExternalEditor.swift")
    expectEqual(editor.components(separatedBy: "guard EnrichCacheReader.isCurrent else {").count - 1 == 2
                && editor.contains("guard Self.content(stored) == session.base else {")
                && editor.contains("LyricsExternalEdit.decide(edited: text, base: session.base)")
                && editor.contains("EnrichCacheStore.shared.saveEdit(") && editor.contains("EnrichCacheStore.shared.savePlainTextEdit(")
                && !editor.contains("effectiveLyricsDir"), true,
                "外部编辑(接法): 读取器解到盘上那一版、正文没变才套,走改动通道,不碰歌词目录")
}

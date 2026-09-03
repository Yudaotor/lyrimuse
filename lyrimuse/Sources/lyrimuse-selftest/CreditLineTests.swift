import LyrimuseCore
import Foundation

// 署名行 / 噪声行过滤(含全库语料回归)。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runCreditLineTests() {
    // ---- LyricsSyncEngine: 署名/制作人员噪声行过滤 ----

    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:00.00]作词 : 甲\n[00:01.00]作曲：乙\n[00:26.74]la la la\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 500)?.mainText, nil, "SyncEngine: 署名行时段内没有真歌词,判定成还没到第一句")
        expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la", "SyncEngine: 真歌词开始后正常显示")
        expectEqual(engine.upcomingLineText(afterMs: 500), "la la la", "SyncEngine: 署名行被过滤后,双行预览提前露出第一句真歌词")
    }

    do {
        let engine = LyricsSyncEngine()
        let yrc = "[0,1000](0,500,0)作词 (500,500,0)：甲 \n[26740,1000](26740,500,0)la (27240,500,0)la \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 500)?.words, nil, "SyncEngine(YRC): 整行都是署名词时整行被过滤")
        expectEqual(engine.activeLine(atMs: 27000)?.words?.map(\.text), ["la ", "la "], "SyncEngine(YRC): 真歌词行不受影响")
    }

    // ---- 歌词噪声过滤:日文标注 / 繁体自动识别 / 纯符号行 ----
    // 2026-08-18 调研 LyricsX 的默认过滤表之后补的。它把繁简两种写法都手工列进表里(有「作詞」
    // 也有「作词」,但「録音」就只列了简体),我们改成转孪生写法再比一次,表不必双写。
    // 日文汉字标注(収録/主題歌/片頭曲)本地缓存里一条样本都没有,是照它那份真实数据提前补的坑。

    do {
        // 日文源常见的头部标注(汉字形态)。
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("主題歌：LiSA"), true,
                    "日文标注: 主題歌")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("片頭曲：藍井エイル"), true,
                    "日文标注: 片頭曲")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("収録：ベストアルバム"), true,
                    "日文标注: 収録")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("挿入歌：花澤香菜"), true,
                    "日文标注: 挿入歌")
        // 繁体标签不再需要在表里双写一份 —— 靠 HanScript 转孪生写法比对。
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("作詞：林夕"), true,
                    "繁体自动识别: 作詞(表里只有简体「作词」)")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("編曲：陳建騏"), true,
                    "繁体自动识别: 編曲")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("錄音：李振權"), true,
                    "繁体自动识别: 錄音")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("歌手：周杰伦"), true,
                    "新增角色词: 歌手")
        // 反例:说话人标签仍然要豁免,别被新词带塌了。
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("他说：我不走"), false,
                    "反例: 对白式冒号不是署名行")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("曲婉婷：好久不见"), false,
                    "反例: 歌手名当说话人标签不是署名行")
    }

    do {
        // 整行只有符号:实测库里存在单独一行 `-`。
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("-"), true, "纯符号行: 单个连字符")
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("——"), true, "纯符号行: 破折号")
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("......"), true, "纯符号行: 省略号")
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("~ * ~"), true, "纯符号行: 混合符号")
        // 反例:括号里有字的**不能**当纯符号删 —— 库里 `(開心啊)` 是真歌词。
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("(開心啊)"), false,
                    "纯符号行(反向): 括号里有字的是真歌词")
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine("Oh"), false, "纯符号行(反向): 短英文语气词")
        expectEqual(LyricsSyncEngine.isSymbolOnlyLine(""), false, "纯符号行(反向): 空行不算")
    }

    // ---- 歌词噪声过滤:抬头 / 版权声明 / 新补角色词 ----
    // 用例全部取自 2026-08-18 对用户真实缓存(490 首、29390 行)的全量扫描:改之前首/末行有
    // 45 条抬头、10 条版权声明、5 条短标签冒号漏网,改之后分别剩 3 / 0 / 0,且 29390 行里零误伤。

    do {
        // ① 简繁:本地标签是繁体,抬头写简体。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("小步舞曲 - 陈绮贞",
                    trackTitle: "小步舞曲", trackArtist: "陳綺貞"), true,
                    "抬头: 简繁不一致也要认出来")
        // ② 多歌手:标签用 & 拼接,抬头用 / 且每个名字后面夹着英文名 —— 整串拼起来连不成一段。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine(
                    "无所谓 (Explicit) - 方大同 (Khalil Fong)/张靓颖 (Jane Zhang)",
                    trackTitle: "无所谓", trackArtist: "方大同 & 张靓颖"), true,
                    "抬头: 多歌手且中间夹英文名")
        // ③ 标签里有抬头没写的合作者。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("电子羊 - 某幻君",
                    trackTitle: "电子羊", trackArtist: "某幻君 & 王瀚哲 (中国BOY)"), true,
                    "抬头: 标签比抬头多一个合作者")
        // ④ 双语歌名:标签是「日出 The Dawn」,抬头只写中文段。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("丁世光 - 日出",
                    trackTitle: "日出 The Dawn", trackArtist: "丁世光"), true,
                    "抬头: 双语歌名只写中文段")
        // ⑤ 短歌名走形状约束那条分支(歌名一两个字,长度下限挡不住它)。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("GF - 方大同",
                    trackTitle: "GF", trackArtist: "方大同"), true, "抬头: 两字母短歌名")
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("追 - 陶喆 (David Zee Tao)",
                    trackTitle: "追", trackArtist: "陶喆"), true, "抬头: 单字歌名")
        // ⑥ 反序、无空格。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("陳柏宇-最後的擁抱",
                    trackTitle: "最后的拥抱", trackArtist: "陈柏宇"), true,
                    "抬头: 歌手在前、无空格、且繁体")
    }

    do {
        // 反向用例:这些**不能**被当成抬头删掉。
        // 真歌词里念自己名字(蛋堡《经典!》的实际歌词,库里存在)。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("新的经典 蛋堡 x Jabberloop",
                    trackTitle: "经典!", trackArtist: "蛋堡"), false,
                    "抬头(反向): 歌词里念自己名字不算抬头")
        // 第一句歌词恰好就是歌名 —— 缺歌手名,不该删(注释里原本就点明的场景)。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("First Love",
                    trackTitle: "First Love", trackArtist: "宇多田ヒカル"), false,
                    "抬头(反向): 只有歌名、没有歌手名")
        // 短歌名那条分支要求"整行就是两段",句中带连字符的真歌词不该命中。
        expectEqual(LyricsSyncEngine.looksLikeHeaderLine("我 - 你 - 他都在等",
                    trackTitle: "我", trackArtist: "某人"), false,
                    "抬头(反向): 多个连字符不算两段形状")
    }

    do {
        // 版权/免责声明:没有冒号,所有"角色+冒号"规则都够不着,所以单独一条。
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经著作权人许可不得翻录翻唱或使用"),
                    true, "版权声明: 郭顶整张专辑末行的实测形态")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经著作权人许可 不得翻录翻唱或使用"),
                    true, "版权声明: 中间带空格的变体")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("（未经许可,不得翻唱或使用）"),
                    true, "版权声明: 带括号的短变体")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("All Rights Reserved"),
                    true, "版权声明: 英文成句写法")
        // 反向:光有"未经"不够,必须成对出现法务词,否则真歌词会被吞。
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("未经允许的心动"), false,
                    "版权声明(反向): 只有「未经」的真歌词不算")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("我不得不承认"), false,
                    "版权声明(反向): 只有「不得」的真歌词不算")
    }

    do {
        // 带版权标记的著作权行(2026-09-02,方大同《白发》)。跟上面那条"成句法务声明"分工:
        // 那条认法务词,这条认版权标记 + 年份 —— 见 matchesCopyrightMarkLine 的注释,那里记着
        // 四条现有规则分别差在哪一步。
        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("著作权人：+© 2019、赋音乐"),
                    true, "版权标记: 《白发》头部的实测形态")
        // 没有冒号、没有汉字标签的写法也要认 —— 这正是单开一条(而不是继续补词表)的收益。
        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("℗ 2016 北京享耳音乐"),
                    true, "版权标记: 录音版权标记开头、无冒号")
        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("(P) 2020 Riot Games"),
                    true, "版权标记: 加括号的 (P) 形态")
        // 反向:两个条件缺一不可。年份是刻意要求的冗余条件(理由见那个函数的注释)。
        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("© 赋音乐"), false,
                    "版权标记(反向): 只有标记没有年份不算")
        expectEqual(LyricsSyncEngine.matchesCopyrightMarkLine("那是 2019 年的夏天"), false,
                    "版权标记(反向): 只有年份的真歌词不算")

        // ---- 第十五轮(2026-09-03,陈绮贞《我亲爱的偏执狂》结尾没过滤干净) ----
        //
        // 那一份结尾 20 行署名里只漏了 2 行,两条新规则各修一行。
        // ⚠️ 定位过程本身值得记:第一版探针逐条调**单行**匹配函数,报出 7 行漏网;换成真实
        // 入口 `creditLineDropDecisions` 之后只剩 2 行 —— 差的是整份闸门(两条形状规则要
        // ≥2 行才认、结构性过滤要"过半")。**改这类规则前必须用整份入口验**,否则会去修 5 处
        // 其实已经拦得住的地方。
        //
        // ① ISRC:没有冒号、也不是角色词开头,上面所有"角色+冒号"形状的规则都够不着。
        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC TWB870211301"), true,
                    "ISRC: 紧凑写法(《我亲爱的偏执狂》实测形态)")
        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC TW-A47-05-32010"), true,
                    "ISRC: 带连字符的分段写法(全库另一种实测形态)")
        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC: TW-B87-02-11301"), true,
                    "ISRC: 带冒号写法")
        // 反向:必须同时有 ISRC 这个词**和**那 12 位编码形状,少一样都不算。
        expectEqual(LyricsSyncEngine.matchesISRCLine("ISRC 是国际标准录音码"), false,
                    "ISRC(反向): 只有词没有编码不算")
        expectEqual(LyricsSyncEngine.matchesISRCLine("TWB870211301"), false,
                    "ISRC(反向): 只有编码没有词不算")

        // ② 「英文角色名 : 拉丁人名」——半角冒号且右边没有中日文那一档。
        // 同一份歌词里 `Executive Producer : 林暐哲` 早就被删(半角那条要求右边有 CJK),
        // `Publisher : Sam Duann` 却留下来,差别就在这儿。
        // ⚠️ 输入里**必须**掺一行真歌词。只给两行署名的话整份会被判全删,触发"展示过滤永远
        // 不把整份删空"那道兜底闸(strippingCreditLines 末尾),两行又被原样放回来 ——
        // 这条断言第一次就是这么红的,红得很有价值:它证明那道安全阀确实在工作。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["其实你很悲伤这很寻常我亲爱的偏执狂",
             "Publisher : Sam Duann", "Mixing : Frankie Hung/Miles Suen"]),
                    [false, true, true],
                    "拉丁角色名+半角冒号: 右边是拉丁人名也要认(真歌词不动)")
        // ⚠️ **反例才是这条规则的安全边界**:白名单刻意不收段落标记词,收了就是成片误杀
        // 真歌词。这几条必须一直是 false。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["Chorus: I don't wanna wait", "Verse 1: walking down the street",
             "Bridge: hold me closer now", "Rap: 欢迎来到我的房间"]),
                    [false, false, false, false],
                    "拉丁角色名(反向): 段落标记(Chorus/Verse/Bridge/Rap)后面跟的是真歌词,一条都不许删")

        // ---- 第十六轮(2026-09-03,李佳薇《甲乙丙丁》头部「艺术指导」漏网) ----
        //
        // 用 App 同一条路径(LRC+YRC → load → allLines)复现:64 行里 16 行署名删了 15 行,只剩
        // 「艺术指导：程楚楚(廊坊师范学院）」。标签「艺术指导」不含 creditRoleWords 任何词;右边
        // 带括注机构、括号半全角混用,不是干净的人名表,形状规则也接不住。
        // 收进表的四个词(指导 / 总监 / 策划 / 导演)全部先拿全库语料量过(3480 首 / 197235 行):
        // 带冒号的全是署名、不带冒号的全是真歌词,冒号那道门正好把两边分开。
        // **before/after 全库差分(3480 首 / 197236 行正文,逐行 diff creditLineDropDecisions)**:
        // KEEP→DROP **1 行**(就是这条),DROP→KEEP **0 行**。另外三个词在语料里零翻转——它们现有
        // 的实例都已经被 matchesNameListCreditShape 的"整份 ≥2 行"闸兜住了,收进表只为
        // "整首只有一行这种署名"的场合(第十轮定下的理由)。差分用的是整份入口,所以也覆盖了
        // 这张表的第二个消费点 englishCreditPattern(它把整张表当可选中文前缀 join 进正则)。
        // ⚠️ 差分工具切行必须按 isNewline:酷狗源 1439 首歌词是 CRLF,Swift 的 "\r\n" 是一个
        // Character,`split(separator: "\n")` 切不开、整份变一行——第一版工具漏掉了这 1439 首,
        // 报出的"2671 首 / 153121 行"是错的。App 自己的 LRCParser 早就为此先归一了换行。
        //
        // ⚠️ 用例里掺真歌词,理由同第十五轮:只给署名行会触发「永不删空」兜底闸把它们原样放回。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["还没来得及习惯", "独自入睡的不安", "艺术指导：程楚楚(廊坊师范学院）", "你外套味道还没散"],
            trackTitle: "甲乙丙丁Strangers", trackArtist: "李佳薇"),
                    [false, false, true, false],
                    "第十六轮: 《甲乙丙丁》那一行带括注机构的「艺术指导」在整份入口里要被删,正文不动")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("艺术指导：程楚楚(廊坊师范学院）"), true,
                    "角色词: 「指导」(艺术指导,右边带括注机构、括号半全角混用)")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("项目总监：闫曼嘉/蔡雨燕/庄有豪"), true,
                    "角色词: 「总监」(丁世光多首头部的项目总监行)")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("总策划:赵宗/唐晶晶"), true,
                    "角色词: 「策划」(半角冒号)")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("导演助理：Minto"), true,
                    "角色词: 「导演」(导演助理,右边单个拉丁名——单行、人名表形状接不住的那种)")
        // 反向哨兵:语料里含这几个词的**真歌词**,一条都不许删。它们都没有冒号(过不了
        // matchesRoleWordCredit 第一道门),也没有 "by/at"(过不了 englishCreditPattern);哪天
        // 有人把"必须有冒号"放宽,这几条先红。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["进入你梦里 指导你演戏", "当你的时尚顾问 别说你不能", "有超多导演跟编剧", "有谁来导演出好戏",
             "唱情歌唱到像顾问一样"]),
                    [false, false, false, false, false],
                    "第十六轮(反向): 周杰伦/陶喆/张敬轩歌词里的 指导/顾问/导演 是真歌词,没有冒号,一条都不许删")

        // 「著作」「推广」进 creditRoleWords(第十四轮)。两条都必须**靠冒号那道门**生效。
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("著作权人：赋音乐"), true,
                    "角色词: 「著作权人」不带版权标记时也认")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("营销推广：戴欣怡 (DDStudio)X深声不息"),
                    true, "角色词: 郑润泽《彻夜》漏网的营销推广行")
        // ⚠️ 回归哨兵:方大同《放不过自己》的**真歌词**「自我执著作怪」里夹着「著作」
        //("自我执著"+"作怪")。它没有冒号,所以 matchesRoleWordCredit 的第一道门就挡住了 ——
        // 这条断言就是钉住"补词表只能在冒号形状里生效"这件事,别哪天把冒号那道门放宽。
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("自我执著作怪"), false,
                    "角色词(反向): 真歌词「自我执著作怪」不因「著作」被误杀")

        // 端到端:《白发》头部实测的 12 行职员表 + 真歌词。改之前只有「著作权人」那行漏网。
        let baifa = [
            "方大同 - 白发", "作词：崔惟楷", "作曲：方大同", "监制：Khalil Fong@JTW",
            "编曲：Khalil Fong", "录音：Fu Music Studio by Jeff Li", "剪辑：Jeff Li",
            "混音：Phil Tan", "母带：Chris Gehringer@Sterling Sound",
            "著作权人：+© 2019、赋音乐", "唱片公司：赋音乐", "推广公司：东亚星光",
            "红尘不复喧哗", "光阴已流成砂", "几许青春年华伴你走天涯", "自我执著作怪",
        ]
        let drops = LyricsSyncEngine.creditLineDropDecisions(
            baifa, trackTitle: "白发", trackArtist: "方大同")
        expectEqual(drops[9], true, "《白发》: 「著作权人：+© 2019、赋音乐」被滤掉")
        expectEqual(drops.prefix(12).allSatisfy { $0 }, true, "《白发》: 头部 12 行职员表一行不剩")
        expectEqual(drops.suffix(4).allSatisfy { !$0 }, true, "《白发》: 四行真歌词一行不少")
    }

    // ---- 署名行过滤第七轮(2026-08-16):带分隔符的中文标签 + 纯英文无冒号 ----
    do {
        typealias E = LyricsSyncEngine
        // 用户报的两行,都出现在歌曲**末尾**
        expectEqual(E.matchesRoleWordCredit("录音师/录音室：王力宏/Homeboy Studios, Taipei, Taiwan"), true,
                    "署名行: 标签含斜杠(录音师/录音室)")
        expectEqual(E.matchesEnglishCredit("Mixed by Wang Leehom at Homeboy Music Studios"), true,
                    "署名行: 纯英文无冒号(Mixed by ...)")
        // 同形态的其它写法
        expectEqual(E.matchesRoleWordCredit("作词&作曲：某人"), true, "署名行: 标签含 &")
        expectEqual(E.matchesRoleWordCredit("混音、母带：某人"), true, "署名行: 标签含顿号")
        expectEqual(E.matchesEnglishCredit("Produced by Someone"), true, "署名行: Produced by")
        expectEqual(E.matchesEnglishCredit("Recorded at Abbey Road"), true, "署名行: Recorded at")

        // ⚠️ 不能误杀的:这些是真歌词
        expectEqual(E.matchesEnglishCredit("a song written by fate"), false, "真歌词: written by 出现在句中不算")
        expectEqual(E.matchesEnglishCredit("Music makes me lose control"), false, "真歌词: 以 Music 开头但没有 by/at")
        expectEqual(E.matchesRoleWordCredit("他说：我不走"), false, "真歌词: 带冒号的对白")
        expectEqual(E.matchesRoleWordCredit("曲婉婷："), false, "对唱标签: 冒号后没内容")
    }

    // ---- 署名行过滤(2026-08-27):中间点「·」当分隔符(QQ 音乐"krc转qrc工具"转出来的形态) ----
    //
    // 用户报丁世光《背面是我》专辑两首 Interlude(《Presentness》《Bygone》)漏网的
    // 「和声 Backing Vocal·Dean Ting」「录音室 Studio·Retro Records Studio」——上面所有规则
    // 都要求半角/全角冒号,这份 KRC 转出来的格式用的是「·」(U+00B7)。只放宽 matchesRoleWordCredit
    // 一条(冒号后面还要过角色词表这道关,误杀面跟冒号版本同一个量级),没有放宽
    // matchesBilingualCreditShape/matchesNameListCreditShape 那两条不查角色词表的免词表规则。
    do {
        typealias E = LyricsSyncEngine
        expectEqual(E.matchesRoleWordCredit("和声 Backing Vocal·Dean Ting"), true,
                    "署名行: 中间点分隔符 + 角色词「和声」")
        expectEqual(E.matchesRoleWordCredit("录音室 Studio·Retro Records Studio"), true,
                    "署名行: 中间点分隔符 + 角色词「录音」(标签含尾字「室」)")
        expectEqual(E.matchesRoleWordCredit("混音与母带工程 Mixing & Mastering Engineer·程振兴 Nathan Cheng"), true,
                    "署名行: 中间点分隔符 + 复合角色词「混音」")

        // ⚠️ 不能误杀的:「·」在真歌词里也会出现(风格化的分隔/人名音译),但没有角色词表命中
        // 就不该被吃掉。
        expectEqual(E.matchesRoleWordCredit("爱·恨都是你给的"), false,
                    "真歌词: 中间点分隔符但左边不是角色词")
    }

    // ---- 署名行过滤(2026-08-27):中文角色词前缀 + 英文署名(无冒号) ----
    //
    // 用户报丁世光《起源》开头「编曲 Arrangement by 丁世光 Dean Ting, 程振兴 Nathan
    // Cheng」没被滤掉:matchesEnglishCredit 要求整行以**英文**角色词开头,前面缀了中文
    // 角色词就直接卡在锚点上。同一首歌后面还有「制作人 Produced by …」,而 creditRoleWords
    // 只收了词根「制作」、没收复合词「制作人」,补前缀支持时还得连带兜住"词根之后还有
    // 尾字"这种情况,不然「制作」两个字之后卡着一个「人」字又会重新落进同一个坑。
    do {
        typealias E = LyricsSyncEngine
        expectEqual(E.matchesEnglishCredit("编曲 Arrangement by 丁世光 Dean Ting, 程振兴 Nathan Cheng"), true,
                    "署名行: 中文角色词(编曲,词根本身就是完整标签) + Arrangement by")
        expectEqual(E.matchesEnglishCredit("制作人 Produced by 丁世光 Dean Ting, 程振兴 Nathan Cheng"), true,
                    "署名行: 中文角色词(制作人,词根「制作」+ 尾字「人」) + Produced by")
        expectEqual(E.matchesEnglishCredit("键盘 Keyboards by 某某"), true,
                    "署名行: 中文角色词(键盘) + Keyboards by")

        // ⚠️ 不能误杀的:真歌词不会以角色词开头又紧跟一个英文角色词 + by。
        expectEqual(E.matchesEnglishCredit("编曲写好了拿给他听"), false,
                    "真歌词: 以角色词「编曲」开头,但后面不是英文角色词+by")
        expectEqual(E.matchesEnglishCredit("制作人还没到"), false,
                    "真歌词: 以角色词「制作」+ 尾字「人」开头,但后面没有 by")
    }

    // ---- 署名行过滤(2026-08-27):纯日期戳注解行(没有冒号,不是角色词开头) ----
    //
    // 用户报丁世光《瘦子》结尾职员表最前面混进一行创作日期戳「July 18, 2012 at 5:25 PM」,
    // 上面所有规则都够不着它——没有冒号,不是角色词开头,也不像版权声明。
    do {
        typealias E = LyricsSyncEngine
        expectEqual(E.matchesDateStampLine("July 18, 2012 at 5:25 PM"), true,
                    "署名行: 完整月份全称 + 日期 + 时间")
        expectEqual(E.matchesDateStampLine("Jan 5, 2020"), true,
                    "署名行: 月份缩写,没有时间后缀")
        expectEqual(E.matchesDateStampLine("  Dec. 25, 1999  "), true,
                    "署名行: 缩写带句点,首尾带空白")

        // ⚠️ 不能误杀的:真歌词提到月份/日期不该被吃掉。
        expectEqual(E.matchesDateStampLine("I miss you every day"), false,
                    "真歌词: 含 day 但不是日期形状")
        expectEqual(E.matchesDateStampLine("May the road rise to meet you"), false,
                    "真歌词: 以月份 May 开头,但不是「月 日, 年」形状")
        expectEqual(E.matchesDateStampLine("我们约好七月十八号见"), false,
                    "真歌词: 中文日期,不在这条判据的形状里(其它规则也够不着,预期漏治)")
    }

    // ---- LyricsSyncEngine: 署名行的结构化判定(2026-08-05) ----
    //
    // 上面那张关键词表已经补过至少两轮(两字全称 → 单字缩写 → "Arranged by:" 这种夹 by 的
    // 写法),每次都是被漏判的真实数据打回来才加的,说明枚举法在这件事上收敛不了。补一条认
    // "短汉字标签 + 冒号 + 内容"这个形状的规则,跟 collector 侧 genericHanCreditLineRe 对齐。
    // 关键是**不能误杀真歌词**,所以下面正反两个方向都要覆盖。

    do {
        let engine = LyricsSyncEngine()
        // 关键词表里没有的角色名(指挥/中提琴/母带),靠结构判定认出来
        let lrc = "[00:00.00]指挥：某人\n[00:01.00]中提琴：某人\n[00:02.00]母带工程师：某人\n[00:26.74]la la la\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 500)?.mainText, nil, "署名行(结构): 关键词表外的角色名也被判成署名行")
        expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la", "署名行(结构): 真歌词不受影响")
        expectEqual(engine.allLines(idPrefix: "t").count, 1, "署名行(结构): 三行职员表全被剔除,只剩 1 行真歌词")
    }

    do {
        let engine = LyricsSyncEngine()
        // ⚠️ 反向:正常歌词里带冒号不能被误杀。这是收窄规则(只认汉字标签、上限 8 字、冒号后
        // 必须有非空白内容)真正要守住的东西——用宽松的 `^.{1,20}[:：].+` 会把这些全吃掉。
        let lrc = """
        [00:10.00]他说：我不走
        [00:20.00]1、2、3：走
        [00:30.00]Verse 1: hello
        [00:40.00]这是一句很长的歌词不是标签所以不该被当成署名行：后面还有内容
        """
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.activeLine(atMs: 11000)?.mainText, "他说：我不走", "署名行(结构): 对白式冒号不误杀")
        expectEqual(engine.activeLine(atMs: 21000)?.mainText, "1、2、3：走", "署名行(结构): 数字编号标签不误杀(只认汉字标签)")
        expectEqual(engine.activeLine(atMs: 31000)?.mainText, "Verse 1: hello", "署名行(结构): 英文场景标签不误杀")
        expectEqual(engine.allLines(idPrefix: "t").count, 4, "署名行(结构): 四句正常歌词一句都没被剔除")
    }

    do {
        // 边界:结构化规则要求"命中 ≥3 行 **且** 过半"。这两条各自单独都不够——
        // ① 只看比例:短曲里一句对白就过半;② 只看行数:长歌里三句对白就被误杀。
        let engine = LyricsSyncEngine()
        // 3 句对白 + 7 句正常歌词 = 命中 3 行达到下限,但只占 3/10 没过半 → 规则不启用,一句不删
        var lines = ["他说：走", "她说：不走", "我说：算了"]
        for i in 0..<7 { lines.append("普通歌词第\(i)句") }
        let lrc = lines.enumerated().map { "[00:\(String(format: "%02d", $0.offset + 10)).00]\($0.element)" }.joined(separator: "\n")
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.allLines(idPrefix: "t").count, 10, "署名行(结构): 命中够 3 行但没过半 → 规则不启用,10 句全留")
    }

    do {
        // 反过来:过半但不够 3 行 → 同样不启用。必须构造成"只有行数这一个条件不满足",否则
        // 测不出这一支——2 行里 1 行命中时 hits*2 > count 是 2 > 2 = false(代码用严格大于),
        // 两个条件同时不满足,断言就算把 `hits >= 3` 删掉也照样通过,等于空转。
        // 3 行里 2 行命中:4 > 3 过半成立,hits=2 < 3 不成立 → 恰好只卡在行数这一条。
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]他说：走\n[00:20.00]她说：不走\n[00:30.00]普通歌词\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.allLines(idPrefix: "t").count, 3, "署名行(结构): 过半但不够 3 行 → 规则不启用,3 句全留")
    }

    do {
        // 审查确认的 IMPORTANT 的回归测试:对唱/口白类 LRC 把**每一句**都标成「男：/女：/合：」,
        // 形状 100% 命中结构正则,"命中 ≥3 行且过半"那道门反而天然被满足 → 整首歌被删空。
        // 说话人标签因此必须整体豁免(既不算 hits、也不会被删)。
        let engine = LyricsSyncEngine()
        let lrc = """
        [00:10.00]男：第一句
        [00:20.00]女：第二句
        [00:30.00]合：第三句
        [00:40.00]男：第四句
        [00:50.00]女：第五句
        """
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.allLines(idPrefix: "t").count, 5, "署名行(结构): 对唱标签(男/女/合)整份豁免,5 句一句不删")
        // 2026-08-14 起前缀不再画在界面上:它被剥进 side 字段用来做左右分栏(见 LyricDuet)。
        // 这条断言原来钉的是 "男：第一句" —— 那正是改动之前的行为(标记直接显示成歌词的一部分,
        // 当前行的逐字填色还会从"男："开始扫)。它保护的"对唱句不能被署名过滤器删掉"这层意思
        // 没变(上面那条 count == 5 才是),这里只是把展示形态更新到新行为。
        expectEqual(engine.activeLine(atMs: 11000)?.mainText, "第一句", "署名行(结构): 对唱句正常展示(前缀已剥)")
        expectEqual(engine.activeLine(atMs: 11000)?.side, .leading, "对唱: 男(先出现)靠左")
        expectEqual(engine.activeLine(atMs: 21000)?.side, .trailing, "对唱: 女(后出现)靠右")
        expectEqual(engine.activeLine(atMs: 31000)?.side, .center, "对唱: 合唱居中")
    }

    do {
        // 兜底闸门:万一判据出了没预料到的偏差、把整份都判成职员表,展示过滤也不许删空——
        // "整片空白/一直显示♪"比"多显示几行职员表"糟糕得多。用关键词表能全命中的一份来验
        // (关键词表是逐行无条件生效的,不受整份门控影响)。
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]作词：甲\n[00:20.00]作曲：乙\n[00:30.00]编曲：丙\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
        expectEqual(engine.allLines(idPrefix: "t").count, 3, "署名行: 会被删空时整份不删(宁可漏治,不可删空)")
    }

    // ---- 署名行:关键词连写 ----
    do {
        // 2026-08-15 用户实测漏网的形状：「词曲：蔡徐坤 KUN/Marco Bernardis/…」被当歌词
        // 显示在悬浮窗上。旧正则要求关键词紧跟冒号，而"词曲"是两个关键词连着写。
        let engine = LyricsSyncEngine()
        engine.load(
            lyrics: """
            [00:01.00]词曲：蔡徐坤 KUN/Marco Bernardis
            [00:02.00]作词作曲：某某某
            [00:03.00]词 曲 编：三个连写还带空格
            [00:04.00]他说：我不走
            [00:05.00]真正的歌词在这里
            [00:06.00]又一句歌词
            [00:07.00]再来一句
            [00:08.00]还有一句
            """,
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 1500)?.mainText, nil, "署名行: 「词曲：」连写被过滤")
        expectEqual(engine.activeLine(atMs: 2500)?.mainText, nil, "署名行: 「作词作曲：」被过滤")
        expectEqual(engine.activeLine(atMs: 3500)?.mainText, nil, "署名行: 「词 曲 编：」带空格连写被过滤")
        // ⚠️ 反例最要紧：带冒号的真歌词不能跟着一起被删掉。
        //
        // 后面那三句普通歌词是**必须**的，不是凑数：整份粒度的结构化规则(1~8 个汉字 + 冒号)
        // 在"命中 >= 3 行且过半"时才启用，而「他说：」正好长这个形状。只写 5 行的话署名行
        // 就把整份主导了，结构化规则一开，这句真歌词会被连坐删掉 —— 那是既有设计的取舍，
        // 不是这次要测的东西。补足真歌词行让比例回到真实歌曲的样子(一两行署名 + 一堆歌词)，
        // 这条断言才是在单独考"关键词连写"那一条规则。
        expectEqual(engine.activeLine(atMs: 4500)?.mainText, "他说：我不走",
                    "署名行: 带冒号的真歌词不被误杀")
        expectEqual(engine.activeLine(atMs: 5500)?.mainText, "真正的歌词在这里", "署名行: 真歌词保留")
    }

    // ---- 署名行:连接词形态 ----
    do {
        // 2026-08-16 用户实测漏网：「制作和编曲：方大同」「所有乐器和编程：Soulboy」显示在
        // 悬浮窗上。角色词之间夹着"和"，旧规则要求角色词紧挨连写就断了。
        // 只放两行署名 + 四行真歌词：结构化规则(要求命中主导整份)在这个比例下不启用，
        // 这里单独考的是关键词规则。
        let engine = LyricsSyncEngine()
        engine.load(
            lyrics: """
            [00:01.00]制作和编曲：方大同
            [00:02.00]所有乐器和编程：Soulboy
            [00:03.00]他说：我不走
            [00:04.00]真正的歌词
            [00:05.00]又一句歌词
            [00:06.00]再来一句
            """,
            lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 1500)?.mainText, nil, "署名行: 「制作和编曲：」被过滤")
        expectEqual(engine.activeLine(atMs: 2500)?.mainText, nil, "署名行: 「所有乐器和编程：」被过滤")
        expectEqual(engine.activeLine(atMs: 3500)?.mainText, "他说：我不走",
                    "署名行: 连接词规则不误杀对白式冒号")
        expectEqual(engine.activeLine(atMs: 4500)?.mainText, "真正的歌词", "署名行: 真歌词保留")
    }

    // ---- 署名行:双字角色词(组合词,首尾都管) ----
    do {
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("数字编辑：Jeff Li"), true,
                    "角色词: 数字编辑(含「编辑」)")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("母带处理：Randy Merrill@Sterling Sound"), true,
                    "角色词: 母带处理(含「母带」)")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("弦乐录制工程师：某某"), true,
                    "角色词: 组合词自动覆盖,不用逐词补表")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("演唱：Jeremy McKinnon (A Day To Remember)、MAX、henry 刘宪华"), true,
                    "角色词: 演唱(第八轮,2026-08-17 用户报的漏网)")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("原唱：张学友"), true, "角色词: 原唱")
        // 反例们:
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("他说：我不走"), false,
                    "角色词: 对白式冒号不误杀")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("曲婉婷：好久不见"), false,
                    "角色词: 歌手名标签(对唱)不误杀 —— 只认双字词,单字「曲」不算")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("回忆："), false,
                    "角色词: 冒号后没内容(语气停顿)不算")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("这一句歌词很长很长超过八个字：也不算"), false,
                    "角色词: 标签超过 8 字不像职员表")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("Mixing：某某"), false,
                    "角色词: 拉丁标签不归这条管(有 latin 规则)")
    }

    // ---- 署名行:双语标签「汉字角色词 + 英文对照」(2026-08-19) ----
    //
    // 用户报陶喆《Stupid Pop Song》开头 13 行职员表一条都没滤掉。原因:label 取的是冒号前的
    // 整段("制作人 Producer"),而原规则要求剔掉分隔符后**全是汉字**,拉丁字母一进来整条就
    // 失败;而结构化那道闸(只在"整份被职员表主导"时才开)对这首也不成立 —— 13 行职员表
    // 配三十多行真歌词,占不到半数。下面这批用的就是酷狗那份的原文。

    do {
        let real = [
            "制作人 Producer：陶喆 David Tao",
            "曲 Composer：陶喆 David Tao",
            "词 Lyricist：陶喆 David Tao/葛大为",
            "编曲 Arrangement and programming：DT",
            "鼓 Drums：Ash Soan",
            "低音吉他 Bass：Paul Bushnell",
            "和声 Background vocals by：DT",
            "制作协力 Production Assistant：陈震豪 Evan Chen",
            "录音室 Recording Studio：新歌录音室 New Song Studios (Taipei)/The Windmill Studio, Norfolk (England)",
            "录音工程师 Recording Engineer：陈震豪 Evan Chen",
            "混音工程师 Mixing Engineer：Mick Guzauski",
            "混音录音室 Mixing Studio：Barking Doctor",
            "母带后期处理工程 Mastering Engineer：CB",
        ]
        for line in real {
            expectEqual(LyricsSyncEngine.matchesRoleWordCredit(line), true,
                        "双语署名: \(line.prefix(12))…")
        }

        // 单字汉字头(「曲」「词」「鼓」)只有在**旁边有英文角色名**时才算 —— 把它们加进
        // creditRoleWords 会把真歌词里的对白吃掉(2026-08-16 踩过并回滚)。
        let notCredits = [
            "他：我不走",                       // 对白,单字说话人
            "妈妈 Mom：吃饭了",                  // 双语但英文不是角色名
            "我爱你 I love you：再见",            // 同上
            "爱情 Love Story：一场游戏",           // "Story" 不在角色名表里
            "曲：我们一起唱",                     // 汉字单字 + 没有英文对照 → 不认
        ]
        for line in notCredits {
            expectEqual(LyricsSyncEngine.matchesRoleWordCredit(line), false,
                        "双语署名(不该命中): \(line.prefix(10))…")
        }

        // ---- 免词表的双语形状(第二轮:用户报「西塔琴 Coral sitar: Jamie Wilson」)----
        //
        // 乐器/职能名是开放集合,词表打不完。改成认形状,但要求整份 ≥2 行才生效。
        let shapeOnly = [
            "西塔琴 Coral sitar：Jamie Wilson",   // 用户报的原文
            "中提琴 Viola：Istvan Loga",
            "竖琴Harp：Michael Maganuco",
            "富鲁格号 Flugehorn: Gary Alesbrook",
            "电钢琴与管风琴 Keys/Organ：丁世光 Dean Ting",
            "词OP：北京大石音乐版权有限公司",
            "画 Painting by：叶喜儿 Ashlee Yip",
        ]
        for line in shapeOnly {
            expectEqual(LyricsSyncEngine.matchesBilingualCreditShape(line), true,
                        "双语形状: \(line.prefix(12))…")
        }
        // ⚠️ 真歌词反例(全库扫出来的唯一一类):行内注解 `(SL:` 让第一个冒号落在括号里,
        // 「冒号前」被当成标签。靠"标签里不许有括号 + 拉丁尾必须字母开头"两道守卫排掉。
        for line in [
            "我们让彼此难过(SL:那些到底算是谁的错) 都别争了",
            "那些伤害人的话(SL:那些只是气话其实我) 都别说了",
        ] {
            expectEqual(LyricsSyncEngine.matchesBilingualCreditShape(line), false,
                        "双语形状(真歌词不许命中): \(line.prefix(10))…")
        }
        // 对唱标注豁免:「男 Male:」这种真实存在,不能当署名删
        expectEqual(LyricsSyncEngine.matchesBilingualCreditShape("男 Male：我不走"), false,
                    "双语形状: 说话人标签豁免")
        // 落单不算 —— 闸在 strippingCreditLines 那边,这里单独验形状函数本身照旧返回 true,
        // 端到端那一组负责验"只有 1 行时不会被删"。
        do {
            let lone = LyricsSyncEngine()
            lone.load(lyrics: "[00:01.00]妈妈 Mom：吃饭了\n[00:05.00]真的歌词一句\n[00:09.00]真的歌词两句\n",
                      lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true)
            expectEqual(lone.allLines(idPrefix: "x").count, 3,
                        "双语形状: 整份只有 1 行这种形状时不删(闸门 ≥2)")
        }

        // 端到端:整份走一遍展示过滤,只剩真歌词那两句
        let engine = LyricsSyncEngine()
        var lrc = "[00:00.00]Stupid Pop Song - 陶喆\n"
        for (i, line) in real.enumerated() {
            lrc += "[00:\(String(format: "%02d", i + 1)).00]\(line)\n"
        }
        lrc += "[00:28.61]This is a stupid pop song 我想唱给你听\n"
        lrc += "[00:33.00]谁在乎明天会怎样\n"
        // 抬头那一行要靠曲名/歌手比对才认得出(见 looksLikeHeaderLine),所以这里必须把它们
        // 传进去 —— 真实调用路径也是这么传的。
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", preferWordLevel: true,
                    trackTitle: "Stupid Pop Song", trackArtist: "陶喆")
        let kept = engine.allLines(idPrefix: "t").compactMap { $0.line.mainText }
        expectEqual(kept, ["This is a stupid pop song 我想唱给你听", "谁在乎明天会怎样"],
                    "双语署名: 端到端只剩两句真歌词(抬头 + 13 行职员表全滤掉)")
    }

    // MARK: - 中文歌不该因为署名行里的日文人名被判成日文(2026-08-20)
    //
    // 用户报「为什么中文歌也给我出罗马音,我没有开中文的,而且有些字有有些字没有」。
    // 实测那首是泠鸢yousa《神的随波逐流》(中文翻唱),整首歌唯一的假名是这两行署名:
    //   [00:07.69]词：れるりり
    //   [00:15.38]曲：れるりり
    // 而语言判定原来扫的是**原始** lyrics 字段(署名行也算),于是整首被判成日文 → 用户关着的
    // 「中文」开关根本没机会说话(闸看的是整首歌的语言)→ 每行中文都被标东西:日语分词器
    // 给得出读音的出日文读音(词典外的字原样留着,就是"有些字有有些字没有"),给不出的退到
    // ICU 音译出拼音。下面用真实歌词片段钉住:开关只开日/韩时,这首歌一行罗马音都不该有。
    do {
        let lyrics = """
        [00:00.00]泠鸢yousa - 神的随波逐流
        [00:07.69]词：れるりり
        [00:15.38]曲：れるりり
        [00:23.08]不知最近为什么总是不随心意
        [00:27.00]但我听说这是我最为珍贵的一个小特长
        [00:31.00]化作无穷的力量
        """
        let jaKoOnly: RomanizationScripts = [.japanese, .korean]

        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                        trackTitle: "神的随波逐流", trackArtist: "泠鸢yousa",
                        romanizationScripts: jaKoOnly)
        let line = engine.activeLine(atMs: 27_500)
        expectEqual(line?.plainText, "但我听说这是我最为珍贵的一个小特长",
                    "中文翻唱: 取到的是正文那一行(署名行已被过滤)")
        expectEqual(line?.romanization, nil,
                    "中文翻唱: 署名行里的日文人名不该让整首歌变成日文 —— 中文开关关着就一行罗马音都没有")

        // 用户把「中文」也打开时,拼音照常出来(这条是设置本来的语义,不能被上面那道修复顺手关掉)。
        let engineZh = LyricsSyncEngine()
        _ = engineZh.load(lyrics: lyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                          trackTitle: "神的随波逐流", trackArtist: "泠鸢yousa",
                          romanizationScripts: [.japanese, .korean, .chinese])
        expectEqual(engineZh.activeLine(atMs: 31_500)?.romanization != nil, true,
                    "中文翻唱: 用户主动打开中文罗马音时照样给")

        // 真正的日文歌不能被这次改动误伤:正文里有假名,照旧判成日文、照旧给读音。
        let jpLyrics = """
        [00:00.00]作词：れるりり
        [00:05.00]火曜日の朝は
        [00:10.00]受話器を取った君
        """
        let jpEngine = LyricsSyncEngine()
        _ = jpEngine.load(lyrics: jpLyrics, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                          trackTitle: "test", trackArtist: "test",
                          romanizationScripts: jaKoOnly)
        expectEqual(jpEngine.activeLine(atMs: 5_500)?.romanization != nil, true,
                    "日文歌: 正文有假名,照旧判成日文并给读音")
    }

    // MARK: - 署名行第十轮:「标签 + 冒号 + 名字串」形状(2026-08-20)
    //
    // 用户报赵雷《成都》头部 13 行职员表里有 4 行漏到展示面上:
    //   [00:09.28]钢琴：柳森    [00:10.60]箱琴：赵雷/喜子
    //   [00:11.93]笛子：祝子    [00:17.23]童声：朵朵/天天
    // 这几个乐器词不在 creditRoleWords 里,而结构化规则被"整份过半"那道闸拦着(13 行署名 vs
    // 三十多行正文)。新规则收紧的是**冒号右边**:必须像人名/团名(不含虚词、每段 2~8 字),
    // 而不是像已撤销的那次那样放宽位置 —— 那次正是被下面这些对白反例打回来的。
    do {
        typealias E = LyricsSyncEngine
        // 正面:这四行就是用户截图里漏网的
        expectEqual(E.matchesNameListCreditShape("钢琴：柳森"), true, "名字串形状: 钢琴：柳森")
        expectEqual(E.matchesNameListCreditShape("箱琴：赵雷/喜子"), true, "名字串形状: 一个角色两个人")
        expectEqual(E.matchesNameListCreditShape("笛子：祝子"), true, "名字串形状: 笛子：祝子")
        expectEqual(E.matchesNameListCreditShape("童声：朵朵/天天"), true, "名字串形状: 童声：朵朵/天天")
        expectEqual(E.matchesNameListCreditShape("弦乐：亚洲爱乐国际乐团"), true, "名字串形状: 团体名(8 字)")
        expectEqual(E.matchesNameListCreditShape("弦乐编写：柳森"), true, "名字串形状: 四字组合标签")
        // 反面:全是历史上真被这条形状误杀过/差点误杀的真歌词
        expectEqual(E.matchesNameListCreditShape("他说：我不走"), false, "名字串形状: 对白(含「我」「不」)不认")
        expectEqual(E.matchesNameListCreditShape("她说：不走"), false, "名字串形状: 对白(含「不」)不认")
        expectEqual(E.matchesNameListCreditShape("我说：算了"), false, "名字串形状: 对白(含「了」)不认")
        expectEqual(E.matchesNameListCreditShape("他说：走"), false, "名字串形状: 右边只有一个字不认")
        expectEqual(E.matchesNameListCreditShape("曲婉婷：好久不见"), false, "名字串形状: 对唱标签+真歌词不认")
        expectEqual(E.matchesNameListCreditShape("男：亲爱的"), false, "名字串形状: 说话人标签豁免")
        expectEqual(E.matchesNameListCreditShape("Verse 1: hello"), false, "名字串形状: 拉丁标签不认")
        expectEqual(E.matchesNameListCreditShape("1、2、3：走"), false, "名字串形状: 数字标签不认")

        // 2026-08-27:丁世光《瘦子》漏网的「项目总监：闫曼嘉/蔡雨燕/庄有豪」——"庄有豪"是
        // 真人名,却含着"看着像句子"那道闸认的停用词"有",单靠整句扫会把整条名单误判成
        // 对白放过。多段(≥2,有 / 、& , 分隔)时改成不再看整句像不像话,只靠逐段的形状校验。
        expectEqual(E.matchesNameListCreditShape("项目总监：闫曼嘉/蔡雨燕/庄有豪"), true,
                    "名字串形状: 多段名单里某一段撞上停用词字(有)也该认")
        // 单段(没有名单分隔符)时这道闸必须还在——不能因为上面那条改动连带放宽了对白。
        expectEqual(E.matchesNameListCreditShape("他说：庄有豪"), false,
                    "名字串形状: 单段(没有 / 、 & , 分隔)时,即使右边像人名也不豁免整句校验")

        // 端到端:真实的《成都》头部(13 行职员表 + 真歌词),四行漏网的必须消失、真歌词必须留下
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: """
        [00:00.00]成都 - 赵雷
        [00:01.32]词：赵雷
        [00:02.65]曲：赵雷
        [00:03.97]编曲：赵雷/喜子
        [00:05.30]制作人：赵雷/喜子/姜北生
        [00:06.63]BASS：张岭
        [00:07.95]鼓：贝贝
        [00:09.28]钢琴：柳森
        [00:10.60]箱琴：赵雷/喜子
        [00:11.93]笛子：祝子
        [00:13.26]弦乐编写：柳森
        [00:14.58]弦乐：亚洲爱乐国际乐团
        [00:15.91]和声：朱奇迹/赵雷/旭东
        [00:17.23]童声：朵朵/天天
        [00:24.00]让我掉下眼泪的
        [00:27.00]不止昨夜的酒
        [00:30.00]让我依依不舍的
        [00:33.00]不止你的温柔
        """, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
        trackTitle: "成都", trackArtist: "赵雷")
        let kept = engine.allLines(idPrefix: "cd").compactMap { $0.line.plainText }
        expectEqual(kept.count, 4, "成都: 13 行职员表 + 抬头全被过滤,只剩 4 句真歌词")
        expectEqual(kept.first, "让我掉下眼泪的", "成都: 第一句真歌词是它")
        expectEqual(kept.contains(where: { $0.contains("钢琴") || $0.contains("箱琴")
                        || $0.contains("笛子") || $0.contains("童声") }), false,
                    "成都: 四行漏网的乐器署名已经过滤掉")
    }

    // MARK: - 署名行过滤:全库语料回归(2026-08-20)
    //
    // 语料 = 用户本机 enrich 缓存里的 **935 首 / 47626 行正文**,用 creditLineDropDecisions 全量
    // 跑过一遍,再按"家族"抽样固化成下面两张表。
    //
    // 为什么要这套:署名行过滤今天已经补到第十轮,每一轮都是"为了多滤掉一类署名"而放宽判据,
    // 而放宽的代价**从来不体现在被滤掉的行上,只体现在被误杀的正文上** —— 不测就没人发现。
    // 这次跑语料当场抓到一整类真误杀:拉丁字母的说话人标签(Rain：/S:/A:/SL：/N.Chen：/Rap:)
    // 连着后面的真歌词被整行删掉,29 行。
    //
    // ⚠️ 判据用 creditLineDropDecisions(整份进、每行出),不是单个匹配函数:整份闸门
    // (双语 ≥2 行、名字串 ≥2 行、结构化 ≥3 行且过半)是这套规则的一半,只测单行函数测不到。
    // 每条样本都放在**最恶劣但真实**的上下文里:旁边摆一段能同时打开"双语形状"和"名字串形状"
    // 两道闸的署名块,再配 8 行普通歌词把"整份主导"那道闸关上(真实歌曲就是这个比例)。
    do {
        typealias E = LyricsSyncEngine
        // 这四行既是真署名(自己都会被删),又把**两道整份闸同时打开** —— 故意的:
        //   前两行标签混着拉丁字母 → 打开"双语形状"闸;
        //   后两行标签是纯汉字     → 打开"名字串形状"闸(混拉丁的标签过不了它的纯汉字要求)。
        // 真实署名块本来就是两种写法混在一起,这也让下面每条 must-keep 都在"两道闸全开"的
        // 最恶劣环境里受检。
        // ⚠️ 后两行必须是**双字**标签:名字串那条规则要求标签至少两个汉字(单字是说话人标签的
        // 地盘),用「词：」「曲：」当 opener 打不开它的整份闸,断言会假绿/假红。
        let openers = ["词 Lyrics：某某某", "曲 Composer：某某某", "作词：某某某", "作曲：某某某"]
        let fillers = [
            "让我掉下眼泪的", "不止昨夜的酒", "余路还要走多久", "你攥着我的手",
            "分开总是在雨天", "一杯凉水一根烟", "谁能凭爱意要富士山私有", "夜色如水淹没了街",
        ]
        /// 把一行放进"真实歌曲"里,返回它删不删。
        func verdict(_ line: String) -> Bool {
            // 目标行放**最后**:第一行有专门的抬头规则(looksLikeHeaderLine),会污染判定。
            let doc = openers + fillers + [line]
            let drop = E.creditLineDropDecisions(doc, trackTitle: "测试曲", trackArtist: "测试歌手")
            return drop[doc.count - 1]
        }

        // ① 必须留下 —— 全库语料里真实出现过的正文/对唱/口白行(第二列是它在语料里出现的次数)
        let mustKeep: [(String, Int)] = [
            ("男：无所谓", 24),
            ("女：无所谓", 6),
            ("合：无所谓", 9),
            ("合：Hey hey ho ho", 8),
            ("合：因为我真的无所谓", 3),
            ("男：多少话也说不出", 3),
            ("女：有时想也想不通", 3),
            ("女：我真的Bae", 3),
            ("男：Khalil", 2),
            ("合：犯错", 2),
            ("钧：迫不及待看见我的未来", 18),
            ("宏：看见我的", 14),
            ("徐：我说男生的无所谓都是自以为", 4),
            ("岩：霸气傲中原 王者扬烽烟", 4),
            ("李：一个人的夜晚 谁和谁陪伴", 3),
            ("华：失去你的我比乞丐落魄", 2),
            ("方：是我闯祸 还是每个月的亲戚害了我", 2),
            ("黄：You are the apple of my eye", 2),
            ("王：不小心", 2),
            ("靖：我们大家的心声", 1),
            ("宏：呦 一位盖世英雄要上台了", 1),
            ("宏：Yeah come on come on", 2),
            ("Rain：给我大声地说我爱你", 12),
            ("Rain：정말 자신 있겠지", 2),
            ("S:只会让我不小心", 2),
            ("S:好想问你", 1),
            ("Rap:欢迎来到我的房间", 1),
            ("SL：啊把日期(給它)撕掉，", 1),
            ("N.Chen：（聽不懂...），", 1),
            ("A: one..two..three…..four", 2),
            ("B: Wu~", 4),
            ("A.B.C.D: Nananana nananana", 5),
            ("我们让彼此难过(SL:那些到底算是谁的错) 都别争了", 1),
            ("（女：Woo I'm sorry Woo So sorry）", 3),
            // 下面两条不是语料原文,是**为收漏网这一轮专门补的防误杀哨兵**:那一轮要放宽
            // "冒号右边是英文名"的长度上限,而英文句子跟英文人名在形状上极像,必须钉住。
            ("他说：I don't wanna go", 0),
            ("Rain：Baby I love you so much", 0),
            // 这两条是**第十一轮跑全库语料当场抓到的新误杀**:放宽"英文名段最长 30 字"之后,
            // 单字说话人标签 + 英文短句(里面没有停用词)被当成署名删掉。护栏是"名字串规则
            // 要求标签至少两个汉字",见 matchesNameListCreditShape。
            ("王：Hey hey ho ho", 2),
            ("靖：All yours baby", 2),
            // 下面 5 条同样来自第十一轮的全库 diff:它们在**第十轮**就已经被吃掉了
            // (单字说话人标签 + 干净短语,当时的 must-keep 样本没覆盖到这个形态),
            // 靠"标签至少两个汉字"这道护栏救回来。一并钉住。
            ("方：开个玩笑", 2), ("宏：盖世英雄到来", 2), ("王：Oh yeah", 2),
            ("华：喔 喔", 1), ("张：回到拉萨", 1),
        ]
        for (line, seen) in mustKeep {
            expectEqual(verdict(line), false, "语料回归(必须留下, 语料 \(seen) 次): \(line)")
        }

        // ② 必须删掉 —— 各家族的真实署名行(第二列是它属于哪一类,方便日后定位是哪条规则退化了)
        let mustDrop: [(String, String)] = [
            ("词：方大同", "中文单字标签"),
            ("曲：陶喆", "中文单字标签"),
            ("作曲 : 方大同", "半角冒号 + 空格"),
            ("编曲：陶喆", "中文双字标签"),
            ("制作人：赵雷/喜子/姜北生", "一个角色多个人"),
            ("钢琴：柳森", "乐器(第十轮补)"),
            ("箱琴：赵雷/喜子", "乐器(第十轮补)"),
            ("笛子：祝子", "乐器(第十轮补)"),
            ("童声：朵朵/天天", "乐器(第十轮补)"),
            ("弦乐：亚洲爱乐国际乐团", "团体名"),
            ("和声：朱奇迹/赵雷/旭东", "多人"),
            ("鼓：贝贝", "单字乐器"),
            ("BASS：张岭", "拉丁标签 + 全角冒号"),
            ("制作人 Producer：陶喆 David Tao", "双语标签"),
            ("曲 Composer：陶喆 David Tao", "双语标签(汉字头是单字)"),
            ("混音工程师 Mixing Engineer：Mick Guzauski", "双语组合词"),
            ("母带后期处理工程师 : Dave Collins", "长组合词 + 半角冒号"),
            ("制作协力 Production Assistant：陈震豪 Evan Chen", "双语组合词"),
            ("OP：月球唱片Retro Records CO LTD.", "版权归属"),
            ("SP：SMAP(BEIJING) CO.,LTD.", "版权归属"),
            ("Written by：Prince", "英文 by 写法"),
            ("Produced by：Sebastien Najand", "英文 by 写法"),
            ("Mixed by：Riot Games", "英文 by 写法"),
            ("Guitar：秋山浩徳", "拉丁角色名 + 日文人名"),
            ("未经著作权人许可不得翻录翻唱或使用", "版权声明(无冒号)"),
            ("版权声明：未经著作权人书面许可，任何人不得以任何方式使用（包括翻唱、翻录等）", "版权声明(带冒号)"),
            // ↓ 2026-08-20 第十一轮:上一轮拿全库语料统计出来的**仍然漏网**的 56 行,按家族收干净
            ("P - Line: 2016 北京享耳音乐文化有限公司Sure Recordings Culture Co., Ltd", "℗/© 版权行"),
            ("C - Line: 2016 北京享耳音乐文化有限公司Sure Recordings Culture Co., Ltd", "℗/© 版权行"),
            ("Protools编辑：Derrick Sepnio/Edward Chan/Kelvin Au/King Kong/Tsam Chan/Nick Wong", "标签混拉丁字母"),
            ("副唱：Bekuh BOOM", "表外角色 + 英文名"),
            ("竖琴：Michael Maganuco", "表外乐器 + 英文名"),
            ("长号：Matt Roberts", "表外乐器 + 英文名"),
            ("键盘乐器 DX7 and synths：Jeff Babko", "双语标签带型号"),
            ("键盘乐器 Keyboards (Piano and synth) by：吴庆隆 Goh Kheng Long", "双语标签带括号和 by"),
            ("中音萨克斯/次中音萨克斯/上低音萨克斯：孟庆泽", "一人身兼多职的长标签"),
            ("合作艺人：(G)I-DLE/Bea Miller/Wolftyla", "表外角色 + 多个英文名"),
            ("主唱：SOYEON of (G)I-DLE/MIYEON of (G)I-DLE/Bea Miller/Wolftyla", "表外角色 + 超长名单"),
            ("Additional Vocal Production by：Oscar Free", "英文角色短语 + by"),
        ]
        for (line, family) in mustDrop {
            expectEqual(verdict(line), true, "语料回归(必须删掉, \(family)): \(line)")
        }

        // ③ 抬头行单独测:它只在**第一行**生效,而且要求同时含曲名和歌手名
        let headerDoc = ["成都 - 赵雷"] + fillers
        expectEqual(E.creditLineDropDecisions(headerDoc, trackTitle: "成都", trackArtist: "赵雷").first,
                    true, "语料回归: 抬头行「曲名 - 歌手」在第一行被删")
        let notHeaderDoc = fillers + ["成都 - 赵雷"]
        expectEqual(E.creditLineDropDecisions(notHeaderDoc, trackTitle: "成都", trackArtist: "赵雷").last,
                    false, "语料回归: 同样的字样出现在中间不当抬头(多半是真歌词)")

        // ④ 永不删空:整份都长成署名的极端输入,一行都不许删(宁可漏治,不可整片空白)
        let allCredits = ["词：某某", "曲：某某", "编曲：某某", "制作人：某某"]
        expectEqual(E.creditLineDropDecisions(allCredits).contains(true), false,
                    "语料回归: 整份都是署名时一行都不删(兜底闸门)")
    }

    // ==== MusicCatalogSearch:目录链接解析的纯函数(2026-08-22 歌词窗口菜单一族) ====
    do {
        typealias S = MusicCatalogSearch
        // ① 请求 URL:参数齐全、term 是 歌手+歌名
        let u = S.searchURL(title: "轨迹", artist: "周杰伦", storefront: "cn")
        expectEqual(u != nil, true, "searchURL 能构造")
        if let u {
            let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func val(_ n: String) -> String? { q.first { $0.name == n }?.value }
            expectEqual(val("term"), "周杰伦 轨迹", "searchURL term=歌手+歌名")
            expectEqual(val("entity"), "song", "searchURL entity=song")
            expectEqual(val("country"), "cn", "searchURL country=店面")
        }
        // ② 挑选优先级:歌名+歌手双松匹配 > 只歌手 > 第一条
        func item(_ t: String, _ a: String) -> S.Item {
            S.Item(trackName: t, artistName: a, collectionName: nil,
                   trackViewUrl: nil, artistViewUrl: nil, collectionViewUrl: nil)
        }
        let items = [item("别的歌", "别人"), item("轨迹 (Live)", "周杰伦"), item("随便", "周杰伦")]
        expectEqual(S.pickBest(items, title: "轨迹", artist: "周杰伦")?.trackName, "轨迹 (Live)",
                    "pickBest: 双匹配优先(标题带版本后缀也认——互相包含)")
        let onlyArtist = [item("别的歌", "别人"), item("随便", "周杰伦")]
        expectEqual(S.pickBest(onlyArtist, title: "轨迹", artist: "周杰伦")?.trackName, "随便",
                    "pickBest: 退而取歌手匹配")
        expectEqual(S.pickBest([item("A", "B")], title: "轨迹", artist: "周杰伦")?.trackName, "A",
                    "pickBest: 再退第一条")
        expectEqual(S.pickBest([], title: "x", artist: "y") == nil, true, "pickBest: 空结果为 nil")
        // 「你的常听·歌手」跳转 title 传空串,只有"只歌手"分支在起作用——2026-08-23 用户
        // 实测点"Prince"跳到了"Prince & The Revolution",根因是旧版对艺人名也用互相包含
        // 的松匹配,单人艺人名恰好是合作艺人名的前缀。精确匹配必须优先于松匹配命中。
        let princeItems = [item("Purple Rain", "Prince & The Revolution"), item("Kiss", "Prince")]
        expectEqual(S.pickBest(princeItems, title: "", artist: "Prince")?.artistName, "Prince",
                    "pickBest: 艺人精确匹配优先于松匹配(Prince 不应被 Prince & The Revolution 抢先)")
        let noExactMatch = [item("Purple Rain", "Prince & The Revolution")]
        expectEqual(S.pickBest(noExactMatch, title: "", artist: "Prince")?.artistName, "Prince & The Revolution",
                    "pickBest: 精确匹配落空时仍退回松匹配")
        // ③ scheme 改写:只认 music.apple.com,其余拒绝(别把任意 https 泛化成 music://)
        expectEqual(S.musicSchemeURL("https://music.apple.com/cn/album/536108118")?.absoluteString,
                    "music://music.apple.com/cn/album/536108118", "musicSchemeURL 改写")
        expectEqual(S.musicSchemeURL("https://example.com/x") == nil, true, "musicSchemeURL 拒绝外域")
        expectEqual(S.musicSchemeURL(nil) == nil, true, "musicSchemeURL nil 输入")
    }
}

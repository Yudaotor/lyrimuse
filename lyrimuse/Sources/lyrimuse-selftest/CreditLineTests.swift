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
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 500)?.mainText, nil, "SyncEngine: 署名行时段内没有真歌词,判定成还没到第一句")
        expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la", "SyncEngine: 真歌词开始后正常显示")
        expectEqual(engine.upcomingLineText(afterMs: 500), "la la la", "SyncEngine: 署名行被过滤后,双行预览提前露出第一句真歌词")
    }

    do {
        let engine = LyricsSyncEngine()
        let yrc = "[0,1000](0,500,0)作词 (500,500,0)：甲 \n[26740,1000](26740,500,0)la (27240,500,0)la \n"
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        expectEqual(engine.activeLine(atMs: 500)?.words, nil, "SyncEngine(YRC): 整行都是署名词时整行被过滤")
        expectEqual(engine.activeLine(atMs: 27000)?.words?.map(\.text), ["la ", "la "], "SyncEngine(YRC): 真歌词行不受影响")
    }

    // ---- 译文 / 罗马音跟着正文的署名判定走(按时间戳配对) ----
    //
    // 真实形态取自酷狗《春不晚 (DJ阿卓版)》:那份 `.tr.lrc` 整份**只有职员表**(正文头部那几行
    // 署名换一种写法再写一遍),而头部最后一行署名(00:00.78)跟第一句真歌词(00:01.45)只差
    // 670ms,落在 `nearestText` 的 700ms 容差里 —— 于是「监制音乐主管：颜陌」被第一句真歌词
    // 就近认领,挂在它下面冒充译文。
    do {
        let engine = LyricsSyncEngine()
        let lrc = "[00:00.62]制作人Music Producer：蔡樱瑞\n[00:00.78]监制Musical Supervisor：颜陌\n"
            + "[00:01.45]我为你挥毫旧谣一番\n[00:08.21]姑娘 一句春不晚\n"
        let tr = "[00:00.62]制作人音乐制作人：蔡樱瑞\n[00:00.78]监制音乐主管：颜陌\n"
        engine.load(lyrics: lrc, lyricsTr: tr, lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 2000)?.mainText, "我为你挥毫旧谣一番",
                    "译文过滤: 正文第一句正常显示")
        expectEqual(engine.activeLine(atMs: 2000)?.translation, nil,
                    "译文过滤: 职员表的译文不许被 700ms 内的第一句真歌词就近认领")
    }

    do {
        // 反向:正文留下来的那行,译文一条都不许被连累。
        let engine = LyricsSyncEngine()
        let lrc = "[00:00.78]监制：颜陌\n[00:01.45]我为你挥毫旧谣一番\n"
        let tr = "[00:00.78]监制音乐主管：颜陌\n[00:01.45]I paint you an old ballad\n"
        engine.load(lyrics: lrc, lyricsTr: tr, lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 2000)?.translation, "I paint you an old ballad",
                    "译文过滤(反向): 正文留下的那行,译文照旧挂着")
    }

    do {
        // 撞车保护:同一个时间戳上既有被判署名的行、又有留下来的真歌词,这个戳不算署名 ——
        // 实测本机 7210 首里有 86 处,多半是 `[00:00.00]` 上抬头行跟第一句挤在一起。
        let engine = LyricsSyncEngine()
        let lrc = "[00:00.00]作词：甲\n[00:00.00]我为你挥毫旧谣一番\n[00:08.21]姑娘 一句春不晚\n"
        let tr = "[00:00.00]I paint you an old ballad\n"
        engine.load(lyrics: lrc, lyricsTr: tr, lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 1000)?.translation, "I paint you an old ballad",
                    "译文过滤(撞车): 同一个戳上还留着真歌词时,它的译文不许被一起丢")
    }

    do {
        // 罗马音同理,而且这条只有认时间戳才接得住:罗马音里的署名是拼音(`zuò cí : jiǎ`),
        // 汉字角色词表一条都够不着 —— 全库量下来这类占被漏掉的大头。
        let engine = LyricsSyncEngine()
        let lrc = "[00:00.78]作词 : 甲\n[00:01.45]一句春不晚\n[00:08.21]留在真江南\n"
        let roma = "[00:00.78]zuò cí : jiǎ\n[00:08.21]liú zài zhēn jiāng nán\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: roma, lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 2000)?.romanization, nil,
                    "罗马音过滤: 拼音写的职员表不许被 700ms 内的第一句就近认领")
        expectEqual(engine.activeLine(atMs: 9000)?.romanization, "liú zài zhēn jiāng nán",
                    "罗马音过滤(反向): 真歌词那行的罗马音照旧")
    }

    // ---- 长得像角色名的标签不许混进演唱者名单 ----
    //
    // 说话人豁免那道门排在署名过滤**所有规则最前面**,一进去就再也不看别的判据 —— 所以一个
    // 角色标签只要被当成演唱者收进名单,同一条 `matchesRoleWordCredit` 判得出它是署名也没用。
    // 真实形态取自《总有幸福在等你》(《欢乐颂》片尾曲):五位演唱者每人一个人名标记,
    // `版权方：东阳正午阳光影视有限公司` 混在里面被当成第六个"演唱者",原样显示在第一行。
    do {
        expectEqual(LyricsSyncEngine.labelLooksLikeCreditRole("版权方"), true,
                    "说话人否决: 「角色词 + 尾字」的标签本身就是角色名")
        for role in ["总策划", "人声编辑", "封面设计", "合声编写", "版权运营", "主唱导演", "声乐编辑"] {
            expectEqual(LyricsSyncEngine.labelLooksLikeCreditRole(role), true,
                        "说话人否决: 全库量出来的同类标签: \(role)")
        }
        // 反向比正向重要:这道否决动的是"谁算演唱者",判错就是把真歌词行的标签当署名。
        for name in ["蒋欣", "乔欣", "王子文", "杨紫", "刘涛", "曲婉婷", "合", "男", "女"] {
            expectEqual(LyricsSyncEngine.labelLooksLikeCreditRole(name), false,
                        "说话人否决(反向): 真演唱者标签一个都不许碰: \(name)")
        }

        let lines = [
            "词：徐梦雅", "曲：捞仔", "版权方：东阳正午阳光影视有限公司",
            "蒋欣：目视前方下巴抬高更漂亮", "乔欣：我很善良不代表我没主张",
            "王子文：天真疯狂偶尔霸道嚣张", "杨紫：左手梦想右手随时疗伤",
            "蒋欣：抖抖肩膀藏好背后的翅膀", "合：总有幸福在等你",
        ]
        let speakers = LyricDuet.speakers(in: lines)
        expectEqual(speakers.contains("版权方"), false, "说话人否决: 「版权方」不进演唱者名单")
        expectEqual(speakers.contains("蒋欣") && speakers.contains("合"), true,
                    "说话人否决: 真演唱者和「合」照旧在名单里")
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(lines, speakerExemptions: speakers),
                    [true, true, true, false, false, false, false, false, false],
                    "说话人否决: 头三行署名全删,五句带人名标记的真歌词一行不动")
    }

    // ---- 歌词噪声过滤:日文标注 / 繁体自动识别 / 纯符号行 ----
    // 调研同类工具的默认过滤表之后补的。那类表把繁简两种写法都手工列进去(有「作詞」
    // 也有「作词」,但「録音」就只列了简体),我们改成转孪生写法再比一次,表不必双写。
    // 日文汉字标注(収録/主題歌/片頭曲)本地缓存里一条样本都没有,是照那份真实数据提前补的坑。

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
    // 用例全部取自对用户真实缓存(490 首、29390 行)的全量扫描:当前规则下首/末行的
    // 抬头/版权声明/短标签冒号漏网分别只剩 3 / 0 / 0 条,29390 行里零误伤。

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

        // 反过来说的「我拿到了授权」那一档:一个法务禁止词都没有,靠"取得类动词 + 授权"成对认。
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("【本音乐作品已获得正版授权】"),
                    true, "授权声明: 括号包着的正版授权声明")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("已通过「腾讯音乐·启明星」获得官方翻唱授权"),
                    true, "授权声明: 动词和「授权」之间隔着平台名")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("（本作品已经过词曲著作权利方授权）"),
                    true, "授权声明: 「经过…授权」写法")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("【英文版翻译自花粥《二十岁的某一天》, 已获词曲授权】"),
                    true, "授权声明: 「已获…授权」写法")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("本作品已獲得正版授權"),
                    true, "授权声明: 繁体写法")
        // 反向:两半必须齐,光有一个「授权」不删 —— 这是它误杀空间小的唯一来源。
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("谁授权你这样对我"), false,
                    "授权声明(反向): 只有「授权」没有取得类动词不算")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("我要赌上我的版权"), false,
                    "授权声明(反向): 语料里真出现过的、含「版权」的真歌词")
        expectEqual(LyricsSyncEngine.matchesCopyrightNotice("我们经过那条街"), false,
                    "授权声明(反向): 只有「经过」的真歌词不算")
    }

    do {
        // 带版权标记的著作权行(方大同《白发》)。跟上面那条"成句法务声明"分工:
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

        // ---- 第十五轮(陈绮贞《我亲爱的偏执狂》结尾没过滤干净) ----
        //
        // 那一份结尾 20 行署名里只漏了 2 行,两条新规则各修一行。
        // 定位方法本身值得记:逐条调**单行**匹配函数的探针会报出 7 行漏网;换成真实
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
        // 输入里**必须**掺一行真歌词。只给两行署名的话整份会被判全删,触发"展示过滤永远
        // 不把整份删空"那道兜底闸(strippingCreditLines 末尾),两行又被原样放回来 ——
        // 这条断言第一次就是这么红的,红得很有价值:它证明那道安全阀确实在工作。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["其实你很悲伤这很寻常我亲爱的偏执狂",
             "Publisher : Sam Duann", "Mixing : Frankie Hung/Miles Suen"]),
                    [false, true, true],
                    "拉丁角色名+半角冒号: 右边是拉丁人名也要认(真歌词不动)")
        // **反例才是这条规则的安全边界**:白名单刻意不收段落标记词,收了就是成片误杀
        // 真歌词。这几条必须一直是 false。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["Chorus: I don't wanna wait", "Verse 1: walking down the street",
             "Bridge: hold me closer now", "Rap: 欢迎来到我的房间"]),
                    [false, false, false, false],
                    "拉丁角色名(反向): 段落标记(Chorus/Verse/Bridge/Rap)后面跟的是真歌词,一条都不许删")

        // ③ 标签整个由英文角色词组成(乐器 / 声部 / 工程,可用 & / , and 连接,可带 by)。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["其实你很悲伤这很寻常我亲爱的偏执狂",
             "Vocals: Harry Styles", "Drum Programming & Synths: Kid Harpoon & Tyler Johnson",
             "Lead & Background Vocals : Michael Jackson", "Cello: Dev Hynes",
             "Background Vocals by：Sam Carter"]),
                    [false, true, true, true, true, true],
                    "拉丁角色词标签: 乐器/声部/工程组成的标签 + 人名要删(真歌词不动)")
        // 反例:单独的修饰词(Solo)不成立;右边是句子的由否决闸放过;人名标签不在词表里。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["其实你很悲伤这很寻常我亲爱的偏执狂",
             "Solo: walking down the road alone", "Bass: I can feel it in my bones",
             "Guitar: my only friend tonight", "Harry: we're not the same"]),
                    [false, false, false, false, false],
                    "拉丁角色词标签(反向): 单独修饰词、右边是句子、人名标签都不许删")
        expectEqual(LyricsSyncEngine.matchesLatinRoleWordLabel("Drum Case Beater : Michael Jackson"), false,
                    "拉丁角色词标签(反向): 标签里有一个词不在词表里就不认")

        // ---- 李佳薇《甲乙丙丁》头部「艺术指导」漏网 ----
        //
        // 用 App 同一条路径(LRC+YRC → load → allLines)验证:64 行里 16 行署名要全删,
        // 「艺术指导：程楚楚(廊坊师范学院）」这条不能漏。标签「艺术指导」不含 creditRoleWords 任何词;右边
        // 带括注机构、括号半全角混用,不是干净的人名表,形状规则也接不住。
        // 收进表的四个词(指导 / 总监 / 策划 / 导演)全部先拿全库语料量过(3480 首 / 197235 行):
        // 带冒号的全是署名、不带冒号的全是真歌词,冒号那道门正好把两边分开。
        // **before/after 全库差分(3480 首 / 197236 行正文,逐行 diff creditLineDropDecisions)**:
        // KEEP→DROP **1 行**(就是这条),DROP→KEEP **0 行**。另外三个词在语料里零翻转——它们现有
        // 的实例都已经被 matchesNameListCreditShape 的"整份 ≥2 行"闸兜住了,收进表只为
        // "整首只有一行这种署名"的场合。差分用的是整份入口,所以也覆盖了
        // 这张表的第二个消费点 englishCreditPattern(它把整张表当可选中文前缀 join 进正则)。
        // 差分工具切行必须按 isNewline:酷狗源 1439 首歌词是 CRLF,Swift 的 "\r\n" 是一个
        // Character,`split(separator: "\n")` 切不开、整份变一行——这样会漏掉这 1439 首,
        // 报出的"2671 首 / 153121 行"是错的。App 自己的 LRCParser 早就为此先归一了换行。
        //
        // 用例里掺真歌词:只给署名行会触发「永不删空」兜底闸把它们原样放回。
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

        // 「著作」「推广」进 creditRoleWords。两条都必须**靠冒号那道门**生效。
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("著作权人：赋音乐"), true,
                    "角色词: 「著作权人」不带版权标记时也认")
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("营销推广：戴欣怡 (DDStudio)X深声不息"),
                    true, "角色词: 郑润泽《彻夜》漏网的营销推广行")
        // 回归哨兵:方大同《放不过自己》的**真歌词**「自我执著作怪」里夹着「著作」
        //("自我执著"+"作怪")。它没有冒号,所以 matchesRoleWordCredit 的第一道门就挡住了 ——
        // 这条断言就是钉住"补词表只能在冒号形状里生效"这件事,别哪天把冒号那道门放宽。
        expectEqual(LyricsSyncEngine.matchesRoleWordCredit("自我执著作怪"), false,
                    "角色词(反向): 真歌词「自我执著作怪」不因「著作」被误杀")

        // 端到端:《白发》头部实测的 12 行职员表 + 真歌词,「著作权人」那行也不能漏。
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

    // ---- 夹心补漏:前后**都**是署名的那一行,自己也是署名 ----
    do {
        // 《探故知》(浅影阿,酷狗源)头部 13 行职员表里只有一行漏到屏幕上:「箫：水玥儿」。
        // 「箫」是**单字**角色标签 —— 关键词表的单字项只有「词曲编唱录混监鼓」,双字角色词
        // 那条按设计不收单字(防的是把对唱标签「曲婉婷：」里的「曲」误杀)。同份里的
        // 二胡/古筝/吉他/混音/监制都在表里,所以只有它一行露出来。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["探故知 - 浅影阿", "词：十七", "曲：孙思达", "编曲：姚亦宸", "吉他：林森密布",
             "二胡：辰小弦", "古筝：紫格", "箫：水玥儿", "混音：杨骄杨", "监制：高启翔",
             "无人可知 窗寒梦时", "一盏孤灯照旧年"],
            trackTitle: "探故知", trackArtist: "浅影阿"),
                    [true, true, true, true, true, true, true, true, true, true, false, false],
                    "夹心: 《探故知》单字乐器标签「箫：」夹在古筝与混音之间要被删,两行真歌词不动")

        // 反向哨兵,钉的是这条规则跟【已撤销】那条「从头尾向内扩展署名块」的分界:
        // 那条只要求**一侧**连着署名块,于是这句紧跟头部署名的真对白被吃掉;这条要求
        // **两侧都是**,它后面跟的是真歌词,条件不成立。哪天有人把「都」放宽成「其一」,
        // 这条先红。
        // 真歌词必须给够:只给五行的话三行命中形状 = 60%,反而把整份结构化过滤的闸门
        // (shouldApplyStructuralCreditFilter,要求 ≥3 行且过半)顶开,这句会被**那条**
        // 规则删掉,测不到夹心这条。这正是文件前面记过的那句「改这类规则前必须用整份入口验」。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["作词：甲", "作曲：乙", "他说：我不走", "我却转身离开", "留下一地尘埃",
             "风把旧信吹散", "月光落在窗前", "谁还记得那年"]),
                    [true, true, false, false, false, false, false, false],
                    "夹心(反向): 紧跟署名块之后的真对白只有一侧是署名,不许删")

        // 对唱分声部标记夹在两条署名中间也不许删 —— 形状判据复用
        // matchesStructuralCreditPattern,它对写死的 男/女/合 标签直接豁免。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions(
            ["作词：甲", "男：琴键上透着光", "编曲：丙", "女：夜色如水流淌", "合：一起走到天亮"]),
                    [true, false, true, false, false],
                    "夹心(反向): 男/女/合 是对唱标记,夹在两条署名之间同样豁免")
    }

    // ---- 署名行过滤:带分隔符的中文标签 + 纯英文无冒号 ----
    do {
        typealias E = LyricsSyncEngine
        // 现象是的两行,都出现在歌曲**末尾**
        expectEqual(E.matchesRoleWordCredit("录音师/录音室：王力宏/Homeboy Studios, Taipei, Taiwan"), true,
                    "署名行: 标签含斜杠(录音师/录音室)")
        expectEqual(E.matchesEnglishCredit("Mixed by Wang Leehom at Homeboy Music Studios"), true,
                    "署名行: 纯英文无冒号(Mixed by ...)")
        // 同形态的其它写法
        expectEqual(E.matchesRoleWordCredit("作词&作曲：某人"), true, "署名行: 标签含 &")
        expectEqual(E.matchesRoleWordCredit("混音、母带：某人"), true, "署名行: 标签含顿号")
        expectEqual(E.matchesEnglishCredit("Produced by Someone"), true, "署名行: Produced by")
        expectEqual(E.matchesEnglishCredit("Recorded at Abbey Road"), true, "署名行: Recorded at")

        // 不能误杀的:这些是真歌词
        expectEqual(E.matchesEnglishCredit("a song written by fate"), false, "真歌词: written by 出现在句中不算")
        expectEqual(E.matchesEnglishCredit("Music makes me lose control"), false, "真歌词: 以 Music 开头但没有 by/at")
        expectEqual(E.matchesRoleWordCredit("他说：我不走"), false, "真歌词: 带冒号的对白")
        expectEqual(E.matchesRoleWordCredit("曲婉婷："), false, "对唱标签: 冒号后没内容")
    }

    // ---- 署名行过滤:中间点「·」当分隔符(QQ 音乐"krc转qrc工具"转出来的形态) ----
    //
    // 举例:丁世光《背面是我》专辑两首 Interlude(《Presentness》《Bygone》)里的
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

        // 不能误杀的:「·」在真歌词里也会出现(风格化的分隔/人名音译),但没有角色词表命中
        // 就不该被吃掉。
        expectEqual(E.matchesRoleWordCredit("爱·恨都是你给的"), false,
                    "真歌词: 中间点分隔符但左边不是角色词")
    }

    // ---- 署名行过滤:中文角色词前缀 + 英文署名(无冒号) ----
    //
    // 举例:丁世光《起源》开头「编曲 Arrangement by 丁世光 Dean Ting, 程振兴 Nathan
    // Cheng」这类:matchesEnglishCredit 要求整行以**英文**角色词开头,前面缀了中文
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

        // 不能误杀的:真歌词不会以角色词开头又紧跟一个英文角色词 + by。
        expectEqual(E.matchesEnglishCredit("编曲写好了拿给他听"), false,
                    "真歌词: 以角色词「编曲」开头,但后面不是英文角色词+by")
        expectEqual(E.matchesEnglishCredit("制作人还没到"), false,
                    "真歌词: 以角色词「制作」+ 尾字「人」开头,但后面没有 by")
    }

    // ---- 署名行过滤:纯日期戳注解行(没有冒号,不是角色词开头) ----
    //
    // 举例:丁世光《瘦子》结尾职员表最前面混进一行创作日期戳「July 18, 2012 at 5:25 PM」,
    // 上面所有规则都够不着它——没有冒号,不是角色词开头,也不像版权声明。
    do {
        typealias E = LyricsSyncEngine
        expectEqual(E.matchesDateStampLine("July 18, 2012 at 5:25 PM"), true,
                    "署名行: 完整月份全称 + 日期 + 时间")
        expectEqual(E.matchesDateStampLine("Jan 5, 2020"), true,
                    "署名行: 月份缩写,没有时间后缀")
        expectEqual(E.matchesDateStampLine("  Dec. 25, 1999  "), true,
                    "署名行: 缩写带句点,首尾带空白")

        // 不能误杀的:真歌词提到月份/日期不该被吃掉。
        expectEqual(E.matchesDateStampLine("I miss you every day"), false,
                    "真歌词: 含 day 但不是日期形状")
        expectEqual(E.matchesDateStampLine("May the road rise to meet you"), false,
                    "真歌词: 以月份 May 开头,但不是「月 日, 年」形状")
        expectEqual(E.matchesDateStampLine("我们约好七月十八号见"), false,
                    "真歌词: 中文日期,不在这条判据的形状里(其它规则也够不着,预期漏治)")
    }

    // ---- LyricsSyncEngine: 署名行的结构化判定 ----
    //
    // 上面那张关键词表已经补过至少两轮(两字全称 → 单字缩写 → "Arranged by:" 这种夹 by 的
    // 写法),每次都是被漏判的真实数据打回来才加的,说明枚举法在这件事上收敛不了。补一条认
    // "短汉字标签 + 冒号 + 内容"这个形状的规则,跟 collector 侧 genericHanCreditLineRe 对齐。
    // 关键是**不能误杀真歌词**,所以下面正反两个方向都要覆盖。

    do {
        let engine = LyricsSyncEngine()
        // 关键词表里没有的角色名(指挥/中提琴/母带),靠结构判定认出来
        let lrc = "[00:00.00]指挥：某人\n[00:01.00]中提琴：某人\n[00:02.00]母带工程师：某人\n[00:26.74]la la la\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.activeLine(atMs: 500)?.mainText, nil, "署名行(结构): 关键词表外的角色名也被判成署名行")
        expectEqual(engine.activeLine(atMs: 27000)?.mainText, "la la la", "署名行(结构): 真歌词不受影响")
        expectEqual(engine.allLines(idPrefix: "t").count, 1, "署名行(结构): 三行职员表全被剔除,只剩 1 行真歌词")
    }

    do {
        let engine = LyricsSyncEngine()
        // 反向:正常歌词里带冒号不能被误杀。这是收窄规则(只认汉字标签、上限 8 字、冒号后
        // 必须有非空白内容)真正要守住的东西——用宽松的 `^.{1,20}[:：].+` 会把这些全吃掉。
        let lrc = """
        [00:10.00]他说：我不走
        [00:20.00]1、2、3：走
        [00:30.00]Verse 1: hello
        [00:40.00]这是一句很长的歌词不是标签所以不该被当成署名行：后面还有内容
        """
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
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
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.allLines(idPrefix: "t").count, 10, "署名行(结构): 命中够 3 行但没过半 → 规则不启用,10 句全留")
    }

    do {
        // 反过来:过半但不够 3 行 → 同样不启用。必须构造成"只有行数这一个条件不满足",否则
        // 测不出这一支——2 行里 1 行命中时 hits*2 > count 是 2 > 2 = false(代码用严格大于),
        // 两个条件同时不满足,断言就算把 `hits >= 3` 删掉也照样通过,等于空转。
        // 3 行里 2 行命中:4 > 3 过半成立,hits=2 < 3 不成立 → 恰好只卡在行数这一条。
        let engine = LyricsSyncEngine()
        let lrc = "[00:10.00]他说：走\n[00:20.00]她说：不走\n[00:30.00]普通歌词\n"
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
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
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.allLines(idPrefix: "t").count, 5, "署名行(结构): 对唱标签(男/女/合)整份豁免,5 句一句不删")
        // 前缀不再画在界面上:它被剥进 side 字段用来做左右分栏(见 LyricDuet)。
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
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.allLines(idPrefix: "t").count, 3, "署名行: 会被删空时整份不删(宁可漏治,不可删空)")
    }

    // ---- 署名行:关键词连写 ----
    do {
        // 实测漏网的形状：「词曲：蔡徐坤 KUN/Marco Bernardis/…」被当歌词
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
        // 反例最要紧：带冒号的真歌词不能跟着一起被删掉。
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
        // 实测漏网：「制作和编曲：方大同」「所有乐器和编程：Soulboy」显示在
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

    // ---- 署名行:双语标签「汉字角色词 + 英文对照」 ----
    //
    // 举例:陶喆《Stupid Pop Song》开头 13 行职员表这类——label 取的是冒号前的
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
        // creditRoleWords 会把真歌词里的对白吃掉(踩过并回滚)。
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

        // ---- 免词表的双语形状(举例:「西塔琴 Coral sitar: Jamie Wilson」)----
        //
        // 乐器/职能名是开放集合,词表打不完。改成认形状,但要求整份 ≥2 行才生效。
        let shapeOnly = [
            "西塔琴 Coral sitar：Jamie Wilson",
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
        // 真歌词反例(全库扫出来的唯一一类):行内注解 `(SL:` 让第一个冒号落在括号里,
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
                      lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
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
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                    trackTitle: "Stupid Pop Song", trackArtist: "陶喆")
        let kept = engine.allLines(idPrefix: "t").compactMap { $0.line.mainText }
        expectEqual(kept, ["This is a stupid pop song 我想唱给你听", "谁在乎明天会怎样"],
                    "双语署名: 端到端只剩两句真歌词(抬头 + 13 行职员表全滤掉)")
    }

    // MARK: - 中文歌不该因为署名行里的日文人名被判成日文
    //
    // 举例:泠鸢yousa《神的随波逐流》(中文翻唱),整首歌唯一的假名是这两行署名:
    //   [00:07.69]词：れるりり
    //   [00:15.38]曲：れるりり
    // 语言判定不能扫**原始** lyrics 字段(署名行也算)——那样会把整首判成日文,用户关着的
    // 「中文」开关根本没机会说话(闸看的是整首歌的语言)→ 每行中文都被标东西:日语分词器
    // 给得出读音的出日文读音(词典外的字原样留着,就是"有些字有有些字没有"),给不出的退到
    // ICU 音译出拼音。下面用真实歌词片段钉住:开关只开日/韩时,这首歌一行罗马音都不该有。
    // ---- 标签独占一行、值换到下一行的署名(「录音室 Recording Studio：」+ 下一行工作室名单) ----
    //
    // 冒号后为空的行一律不认(真歌词里「我对你说：」是语气停顿),值那一行又没有标签 ——
    // 两行各自都够不着任何规则。只在标签是**双语且英文半边就是角色名**时才认这一对。
    do {
        let D = { (t: [String]) in LyricsSyncEngine.creditLineDropDecisions(t) }
        for colon in ["：", ":"] {
            let song = [
                "作词 Lyricist：丁世光",
                "作曲 Composer：丁世光",
                "录音室 Recording Studio\(colon)",
                "Retro Records Studio (BJ)/Barzilay Studio (LA)/Nathan's Studio (BJ)",
                "雨不停下 不停下",
                "似乎要把整座城市的忍耐都冲垮",
            ]
            expectEqual(D(song), [true, true, true, true, false, false],
                        "标签独占一行: 标签行和下一行的名单一起删,真歌词不动(冒号 \(colon))")
        }
        // 下一行不像名单(没有 / 、 , 也没有括号):只删标签行,那一行留着。
        expectEqual(D(["录音室 Recording Studio：", "雨不停下 不停下", "似乎要把整座城市的忍耐都冲垮"]),
                    [true, false, false], "标签独占一行: 下一行像歌词就不连带")
        // 纯中文标签独占一行不认 —— 可能是一句以冒号收尾的歌词。
        expectEqual(D(["我对你说：", "我爱你/你爱我", "雨不停下 不停下"]), [false, false, false],
                    "标签独占一行: 纯中文句子以冒号收尾不是署名")
        expectEqual(D(["我的制作人说：", "别再唱了(真的)", "雨不停下 不停下"]), [false, false, false],
                    "标签独占一行: 纯中文标签即使含角色词也不认")
        // 英文半边不是角色名(对唱 / 说话人那一类)不认。
        expectEqual(D(["妈妈 Mom：", "吃饭了/快点", "雨不停下 不停下"]), [false, false, false],
                    "标签独占一行: 英文半边不是角色名不认")
        // 标签行在最后一行:只删它自己,不越界。
        expectEqual(D(["雨不停下 不停下", "录音室 Recording Studio："]), [false, true],
                    "标签独占一行: 在最后一行也只删它自己")
    }

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

        // 真正的日文歌不能被误伤:正文里有假名,照旧判成日文、照旧给读音。
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

    // MARK: - 署名行:「标签 + 冒号 + 名字串」形状
    //
    // 举例:赵雷《成都》头部 13 行职员表里这 4 行:
    //   [00:09.28]钢琴：柳森    [00:10.60]箱琴：赵雷/喜子
    //   [00:11.93]笛子：祝子    [00:17.23]童声：朵朵/天天
    // 这几个乐器词不在 creditRoleWords 里,而结构化规则被"整份过半"那道闸拦着(13 行署名 vs
    // 三十多行正文)。新规则收紧的是**冒号右边**:必须像人名/团名(不含虚词、每段 2~8 字)。
    // 别放宽位置判据本身——下面这些对话反例就是用来防它的。
    do {
        typealias E = LyricsSyncEngine
        // 正面:这四行就是对拍里漏网的
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

        // 丁世光《瘦子》漏网的「项目总监：闫曼嘉/蔡雨燕/庄有豪」——"庄有豪"是
        // 真人名,却含着"看着像句子"那道闸认的停用词"有",单靠整句扫会把整条名单误判成
        // 对白放过。多段(≥2,有 / 、& , 分隔)时改成不再看整句像不像话,只靠逐段的形状校验。
        expectEqual(E.matchesNameListCreditShape("项目总监：闫曼嘉/蔡雨燕/庄有豪"), true,
                    "名字串形状: 多段名单里某一段撞上停用词字(有)也该认")
        // 单段(没有名单分隔符)时这道闸必须还在——不能因为上面那条改动连带放宽了对白。
        expectEqual(E.matchesNameListCreditShape("他说：庄有豪"), false,
                    "名字串形状: 单段(没有 / 、 & , 分隔)时,即使右边像人名也不豁免整句校验")

        // ---- 第十七轮(麦浚龙 & 陈蕾《不下床》开头那行括号人名单漏网) ----
        // 那行既没角色词也没冒号,上面这条(第一句就 guard 冒号)和关键词表(要角色词)都够不着。
        // 这条规则的**全部精度**来自"≥3 段",分界是拿本机全库 10,799 份 LRC / 543,555 行量的:
        // 用 `/` 分隔的括号行,2 段共 12 行全是真歌词、≥3 段共 4 行全是署名。
        expectEqual(E.matchesParenNameListCreditShape(
            "(Natalia Cheung/Hung Man Ting/Edan Yau/Karim Har/Ng Wai Lok/Richard Hu"
            + "/Chris Chau/Hei Lum Chan/Joe Cheung/Ray Siu/Hin Chan)"), true,
            "括号名单: 《不下床》11 人参与者名单")
        expectEqual(E.matchesParenNameListCreditShape("(Slow Rabbit/Misha/YEONJUN/PXPILLON)"),
                    true, "括号名单: 4 段(语料实例)")
        expectEqual(E.matchesParenNameListCreditShape(
            "（Kanata Okajima/dyvahh/LUZY/JISOO/MOMOKA/Yuika）"), true,
            "括号名单: 全角括号 6 段(语料实例)")
        expectEqual(E.matchesParenNameListCreditShape("(周杰伦/方文山/林迈可)"), true,
                    "括号名单: 中文名 3 段")
        // 反面才是这条的安全边界。**2 段是真歌词的地盘** —— 全库那 12 行全长这样。
        expectEqual(E.matchesParenNameListCreditShape("(U were dancing so hard/strong)"), false,
                    "括号名单: 2 段不认(Prince《Girls & Boys》真歌词)")
        expectEqual(E.matchesParenNameListCreditShape("(U won't resist it/to it)"), false,
                    "括号名单: 2 段不认(同一首)")
        expectEqual(E.matchesParenNameListCreditShape("（你在房间/大厅的另一端）"), false,
                    "括号名单: 2 段不认(同一首的译文)")
        // 同一份《不下床》里另有 16 行括号和声,没有 `/`,一条都不许被这条吃掉。
        expectEqual(E.matchesParenNameListCreditShape("(躺着看天花那光影)"), false,
                    "括号名单: 无 / 的和声行不认")
        expectEqual(E.matchesParenNameListCreditShape("(睡在大床上 依偎你 车声也动听)"), false,
                    "括号名单: 无 / 的和声行不认(长句)")
        // 逗号**刻意不算分隔符**:收了会把这类和声整片吃掉(语料里带逗号的 ≥2 段括号行 453 行)。
        expectEqual(E.matchesParenNameListCreditShape("(Straight up, straight up, straight up)"),
                    false, "括号名单: 逗号不算分隔符")
        expectEqual(E.matchesParenNameListCreditShape("(Let go, let go, let go)"), false,
                    "括号名单: 逗号不算分隔符(2)")
        expectEqual(E.matchesParenNameListCreditShape("(Ooh, yeah)"), false,
                    "括号名单: 逗号不算分隔符(3)")
        // 段里含虚词就不是人名,即使真有 `/`。
        expectEqual(E.matchesParenNameListCreditShape("(我不走/你别来/他要走)"), false,
                    "括号名单: 段里含 nonNameChars 不认")
        // 括号这个强信号本身也是判据的一部分。
        expectEqual(E.matchesParenNameListCreditShape("Natalia Cheung/Hung Man Ting/Edan Yau"),
                    false, "括号名单: 裸名单(无括号)刻意不治")
        expectEqual(E.matchesParenNameListCreditShape("(和声) 某某 (和声)"), false,
                    "括号名单: 内部还有同种括号不认")

        // 端到端:《不下床》真实片段 —— 名单行消失,同一份里的括号和声一行不动。
        expectEqual(LyricsSyncEngine.creditLineDropDecisions([
            "(Natalia Cheung/Hung Man Ting/Edan Yau/Karim Har/Ng Wai Lok/Richard Hu"
            + "/Chris Chau/Hei Lum Chan/Joe Cheung/Ray Siu/Hin Chan)",
            "捧着你 小粉脸 欣赏",
            "(躺着看天花那光影)",
            "(睡在大床上 依偎你 车声也动听)",
            "(别理外间 打打杀杀)",
        ]), [true, false, false, false, false],
            "括号名单 端到端: 只删名单行,和声行全留")

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

    // MARK: - 署名行过滤:全库语料回归
    //
    // 语料 = 用户本机 enrich 缓存里的 **935 首 / 47626 行正文**,用 creditLineDropDecisions 全量
    // 跑过一遍,再按"家族"抽样固化成下面两张表。
    //
    // 为什么要这套:署名行过滤今天已经补到第十轮,每一轮都是"为了多滤掉一类署名"而放宽判据,
    // 而放宽的代价**从来不体现在被滤掉的行上,只体现在被误杀的正文上** —— 不测就没人发现。
    // 这次跑语料当场抓到一整类真误杀:拉丁字母的说话人标签(Rain：/S:/A:/SL：/N.Chen：/Rap:)
    // 连着后面的真歌词被整行删掉,29 行。
    //
    // 判据用 creditLineDropDecisions(整份进、每行出),不是单个匹配函数:整份闸门
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
        // 后两行必须是**双字**标签:名字串那条规则要求标签至少两个汉字(单字是说话人标签的
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
            // 下面拿全库语料统计出来的**仍然漏网**的 56 行,按家族收干净
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

    // ==== MusicCatalogSearch:目录链接解析的纯函数(歌词窗口菜单一族) ====
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
        // 「你的常听·歌手」跳转 title 传空串,只有"只歌手"分支在起作用——精确匹配必须
        // 优先于松匹配命中,否则单人艺人名会被合作艺人名(互相包含关系)的松匹配抢先命中,
        // 比如"Prince"被"Prince & The Revolution"抢走。
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

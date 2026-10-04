package main

import "testing"

// 歌词文本里本身带圆括号的词(「Adele (阿黛尔)」的那个左右括号各自是一个词)必须照常转换。
//
// 这是个真实的线上缺陷,不是假想:旧实现用一条
// `([^\[\]()\n]+)\((\d+),(\d+)\)` 整份替换,词文本的字符类把 `(` `)` 排除了,于是带括号的
// 那个词匹配不上、原样留着 QRC 的两数字写法漏进 YRC。本机缓存实测 842 条 QQ 条目中招。
func TestQRCToYRCKeepsParenthesesWords(t *testing.T) {
	// 取自 Adele《River Lea》署名行的真实形态(QRC 原文:词在前、标记在后)。
	const qrc = "[0,6030]River (0,926)Lea (926,926)- (1852,926)Adele(2778,463) (3241,463)((3704,463)阿(4167,463)黛(4630,463)尔(5093,463))(5556,463)"
	// 期望值里「Adele」那个词的时长是 926 而不是 463:它后面那个纯空白词条
	// (3241,463,0) 已经在**源头**被归并进来了(见 qrcToYRC 末尾),时长延到 3704-2778=926。
	// 两个括号词 ( 和 ) 各自成词、各带自己的三数字标记 —— 那正是这条用例要守的。
	const want = "[0,6030](0,926,0)River (926,926,0)Lea (1852,926,0)- (2778,926,0)Adele (3704,463,0)((4167,463,0)阿(4630,463,0)黛(5093,463,0)尔(5556,463,0))"
	if got := qrcToYRC(qrc); got != want {
		t.Errorf("带括号的词没转对\n实际: %s\n期望: %s", got, want)
	}
}

// 纯空白词条必须在**源头**就归并掉,不留给启动期那道迁移。
//
// 两件事在这里交汇,所以放一条用例里守:① 旧实现没转的两数字词条会把前一个空白词条"粘住",
// 归并器按三数字切分、切不出来就判「不用改」,那些空格于是永远留着(现象是"某个字没有读条、
// 直接填满");② 就算切得出来,以前也没人在源头调归并器 —— 全仓只有 migrateYRCWhitespaceTokens
// 调它,于是每解析一首新歌就又产生一批,那道"迁移"跑了 39 次也收敛不了。
func TestQRCToYRCMergesWhitespaceAtSource(t *testing.T) {
	const qrc = "[0,6030]Adele(2778,463) (3241,463)((3704,463)阿(4167,463)"
	// 空格并进前一个词「Adele」,时长延到空白词条的终点(3241+463=3704)。
	const want = "[0,6030](2778,926,0)Adele (3704,463,0)((4167,463,0)阿"
	yrc := qrcToYRC(qrc)
	if yrc != want {
		t.Errorf("源头归并结果不对\n实际: %s\n期望: %s", yrc, want)
	}
	// 再跑一遍归并器应当无事可做 —— 源头已经干净,启动期那道迁移不该再为新数据跑起来。
	if _, changed := yrcMergeWhitespaceTokens(yrc); changed {
		t.Error("源头出来的 YRC 里不该还剩纯空白词条")
	}
}

// 常规一行(没有任何括号)转换前后逐字不变 —— 保证这次改写没动到主干行为。
func TestQRCToYRCPlainLine(t *testing.T) {
	const qrc = "[1000,2000]hello (0,500)world(500,600)"
	const want = "[1000,2000](0,500,0)hello (500,600,0)world"
	if got := qrcToYRC(qrc); got != want {
		t.Errorf("常规行转换变了\n实际: %s\n期望: %s", got, want)
	}
}

// 元数据行(没有词计时)原样保留,不能被切碎。
func TestQRCToYRCLeavesMetadataLines(t *testing.T) {
	const qrc = "[ti:River lea]\n[ar:Adele]\n[1000,500]a(0,500)"
	const want = "[ti:River lea]\n[ar:Adele]\n[1000,500](0,500,0)a"
	if got := qrcToYRC(qrc); got != want {
		t.Errorf("元数据行被动了\n实际: %q\n期望: %q", got, want)
	}
}

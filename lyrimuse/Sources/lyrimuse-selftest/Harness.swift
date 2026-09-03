import Foundation

// 手写的极简断言跑法:这台机器没有完整 Xcode,XCTest/Testing 两个测试框架都用不了
// ("no such module"),所以用普通可执行 target + assert 风格的比较代替,`swift run
// lyrimuse-selftest` 跑一遍即可,失败时进程以非零状态码退出。所有用例都是合成
// 字符串,不含真实歌词文本。
//
// 计数器是全局的:各领域文件里的 runXxxTests() 只管调 expectEqual / expectNotEqual,
// 计数、--quiet、分组汇总都在这里和 main.swift 里 —— 领域文件里别自己 print 结果行。

/// 失败条数;main.swift 按它决定退出码。
var failures = 0
/// 跑过的断言总数(含失败),用来在汇总里打「N 组 / M 条断言」防止整组漏跑。
var assertions = 0
/// --quiet:不打 ok 行(FAIL 行照打)。
var quietOutput = false

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    assertions += 1
    if actual == expected {
        if !quietOutput { print("ok - \(label)") }
    } else {
        failures += 1
        print("FAIL - \(label)\n    actual:   \(actual)\n    expected: \(expected)")
    }
}

func expectNotEqual<T: Equatable>(_ actual: T, _ unexpected: T, _ label: String) {
    assertions += 1
    if actual != unexpected {
        if !quietOutput { print("ok - \(label)") }
    } else {
        failures += 1
        print("FAIL - \(label)\n    两者相等,但期望不同:  \(actual)")
    }
}

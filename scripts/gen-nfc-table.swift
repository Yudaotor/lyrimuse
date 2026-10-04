// 从 Foundation(App 侧 precomposedStringWithCanonicalMapping 用的同一套 Unicode 数据)导出 NFC 所需的
// 数据表,给引擎的 composeNFC(nfc.go)读。
//
// 用法:
//     swift scripts/gen-nfc-table.swift            # 重新生成 lyrimuse-engine/dictionary/NFC.txt
//     swift scripts/gen-nfc-table.swift --check    # 只校验产物是不是最新
//
// 为什么用 Swift 导出而不是 Python 的 unicodedata:cleanMediaTag / cleanTag 两侧逐码点对拍
// (keyparitysweep_test.go ↔ CacheKeyTests),Go 侧的 NFC 必须跟 App 侧 Foundation 的结果逐码点一致;
// 系统自带的 Python 跟 macOS 的 Unicode 版本不是同一个。引擎零依赖(见 fold.go 头注),不引
// golang.org/x/text,所以表由这里生成、跟着仓库提交。
//
// 产物每行一条,十六进制码点:
//     c <cp> <ccc>            组合类非零的码点
//     d <cp> <cp1> <cp2> ...  完整规范分解(韩文音节不列,Go 侧按算法分解)
//     p <a> <b> <composite>   一级组合对:a + b → composite(只收规范组合不排除的那些)
//     q <lo> <hi>             NFC 快速检查要进慢路径的码点区间:组合类非零、NFC 后会变、或能跟前一个字组合
import Foundation

let outPath = "lyrimuse-engine/dictionary/NFC.txt"

func hex(_ v: UInt32) -> String { String(v, radix: 16, uppercase: true) }

func isHangulSyllable(_ v: UInt32) -> Bool { v >= 0xAC00 && v <= 0xD7A3 }

var cccLines: [String] = []
var decompLines: [String] = []
var pairLines: [String] = []
var trigger = Set<UInt32>()

for v in UInt32(0)...0x10FFFF {
    guard let s = Unicode.Scalar(v) else { continue } // 代理区
    let str = String(Character(s))
    let ccc = s.properties.canonicalCombiningClass.rawValue
    if ccc != 0 {
        cccLines.append("c \(hex(v)) \(ccc)")
        trigger.insert(v)
    }
    if str.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value) != [v] {
        trigger.insert(v)
    }
    if isHangulSyllable(v) { continue }
    let d = Array(str.decomposedStringWithCanonicalMapping.unicodeScalars)
    guard d.count > 1 || (d.count == 1 && d[0].value != v) else { continue }
    decompLines.append("d \(hex(v)) " + d.map { hex($0.value) }.joined(separator: " "))
    // 一级组合对:v 是规范组合的结果(NFC(分解) == v),而且分解的最后一个码点之前那一段能组合成单个码点。
    guard d.count >= 2,
          String(String.UnicodeScalarView(d)).precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value) == [v]
    else { continue }
    let head = Array(String(String.UnicodeScalarView(d.dropLast())).precomposedStringWithCanonicalMapping.unicodeScalars)
    guard head.count == 1, let last = d.last else { continue }
    pairLines.append("p \(hex(head[0].value)) \(hex(last.value)) \(hex(v))")
    trigger.insert(last.value)
}
// 韩文字母:元音 / 收音能跟前面的字组成音节(算法组合),同样要进慢路径。
for v in UInt32(0x1161)...0x1175 { trigger.insert(v) }
for v in UInt32(0x11A8)...0x11C2 { trigger.insert(v) }

// 快速检查区间:把相邻码点并成区间。
var ranges: [String] = []
let sorted = trigger.sorted()
var i = 0
while i < sorted.count {
    var j = i
    while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
    ranges.append("q \(hex(sorted[i])) \(hex(sorted[j]))")
    i = j + 1
}
precondition(sorted.first.map { $0 >= 0x300 } ?? true, "快速检查假定 U+0300 以下不用进慢路径")

let header = """
# 由 scripts/gen-nfc-table.swift 生成,不要手改。数据来源:Foundation(macOS \(ProcessInfo.processInfo.operatingSystemVersionString))。
# 行格式见生成脚本头注。

"""
let body = header + (cccLines + decompLines + pairLines + ranges).joined(separator: "\n") + "\n"

if CommandLine.arguments.contains("--check") {
    let current = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
    func strip(_ s: String) -> String { s.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n") }
    if strip(current) != strip(body) {
        FileHandle.standardError.write("\(outPath) 不是最新,重新跑 swift scripts/gen-nfc-table.swift\n".data(using: .utf8)!)
        exit(1)
    }
    print("\(outPath) 是最新的")
} else {
    try! body.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("wrote \(outPath): \(cccLines.count) ccc, \(decompLines.count) decompositions, \(pairLines.count) pairs, \(ranges.count) quick-check ranges")
}

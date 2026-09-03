// 探测 ICU 的 Traditional-Simplified 转换对给定汉字**转不转**——scripts/gen-han-variants.py
// 的一个步骤,不是独立工具。
//
// 为什么必须真的跑一次 ICU:异体字表要回答的是"两个转换引擎各自漏了哪些字"。Go 侧用
// OpenCC 词库(lyrimuse-collector/t2s.go,词典数据能离线枚举),Swift 侧用 ICU
// (Romanizer.converted 里的 `applyingTransform(StringTransform("Traditional-Simplified"))`,
// 覆盖面**没有**可离线枚举的数据文件)。生成器只能实测:把候选字逐个喂给 ICU,看它转不转、
// 转成什么。生成表里"这一条填的是谁的缺口"那一列就是这么来的。
//
// stdin 读候选(每行一个汉字),stdout 按 `字<TAB>icu产物` 输出;ICU 不转时产物等于原字。
import Foundation

let transform = StringTransform("Traditional-Simplified")
while let line = readLine(strippingNewline: true) {
    let ch = line.trimmingCharacters(in: .whitespaces)
    guard !ch.isEmpty else { continue }
    let converted = ch.applyingTransform(transform, reverse: false) ?? ch
    print("\(ch)\t\(converted)")
}

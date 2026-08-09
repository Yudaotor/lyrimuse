import SwiftUI

/// 跟 `Label(_:systemImage:)` 用法一致,但**强制图标用拉丁字母变体**渲染。
///
/// SF Symbols 里 `textformat.abc` 这类"字母表"符号会跟着 locale 变形。2026-08-09 用
/// ImageRenderer 逐个 locale 实测:
///
///     en → Abc      zh → 甲乙丙      ja → あいう      ko → 가나다
///
/// 这个特性本身是好的,别处该留着——比如「译文」用的 `character.book.closed`,中文下画的
/// 是封面写着"字"的词典,比英文原版更贴切。
///
/// 但用在「罗马音」上它是**自相矛盾**的:罗马音的意思恰恰是"把歌词转写成拉丁字母",
/// 中文界面下却画出三个汉字,用户看到的是「甲乙丙 罗马音」——图标在说的和标签在说的正好相反
/// (用户实际问过这三个字是什么意思)。这里把 locale 钉死成 en,让它老老实实画 "Abc"。
///
/// locale 只钉在这一个 Image 上,旁边的文字不受影响:那是 `L10n.t()` 提前查好的字符串,
/// 跟 environment 里的 locale 无关。
///
/// ⚠️ 新增用法前先想清楚:只有"这个图标必须是拉丁字母才说得通"时才该用它,不是所有
/// 会本地化的符号都该被钉住。
struct LatinIconLabel: View {
    private let title: String
    private let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .environment(\.locale, Locale(identifier: "en"))
        }
    }
}

import LyrimuseCore
import SwiftUI

extension View {
    /// 按 `LyricTypesetting` 给这段歌词标排字语言(决定缺字时系统挑哪一地区的字形)。不用标时原样返回。
    /// 画歌词的 `Text` 都要套它,口径跟 AppKit 那边量宽度、画字的 `LyricTypesetting.attributes` 一致。
    /// `translation`:这段是译文。
    @ViewBuilder
    func lyricTypesetting(_ text: String?, translation: Bool = false) -> some View {
        if let text, let language = LyricTypesetting.language(for: text, translation: translation) {
            typesettingLanguage(Locale.Language(identifier: language))
        } else {
            self
        }
    }
}

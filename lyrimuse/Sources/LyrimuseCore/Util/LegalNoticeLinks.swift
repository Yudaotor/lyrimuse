import Foundation

/// 「使用与版权说明」的落点。
///
/// 说明正文只维护在仓库 README 的「许可与版权说明」一节(中英日韩各一份),App 里不抄第二份:这段话改的
/// 频率(加一个歌词源、换一个机翻后端、多一处对外请求)远高于 App 发版,抄进 xcstrings 就是第二份
/// 要同步的真源。这里只做"按界面语言挑哪份 README、拼哪个锚点"这一个纯判断;打开动作在 App 侧
/// `LegalNotices`,两处入口(设置「关于」页、引导欢迎页)都走它。
public enum LegalNoticeLinks {
    public static let repo = "https://github.com/Yudaotor/lyrimuse"

    /// 随包分发的 THIRD_PARTY_LICENSES 在 GitHub 上的同一份;包里那份打不开时的兜底。
    public static let thirdPartyLicensesOnGitHub = URL(string: repo + "/blob/main/THIRD_PARTY_LICENSES")!

    /// 仓库根的 LICENSE(GPL-3.0 全文)。关于页「开源许可证」那一行开它。
    public static let licenseOnGitHub = URL(string: repo + "/blob/main/LICENSE")!

    /// `language` 是 `L10n.current` 的取值("en" / "zh-hans" / "zh-hant" / "ja" / "ko" / "es" / "fr" / "de" / "it" / "pt-br" / "vi")。中文两档开同一份中文
    /// README;认不出的值当英文。锚点是 GitHub 按标题生成的:中日韩标题原样(空格换连字符,URL 里百分号编码,
    /// `URLComponents.fragment` 会做),英文标题小写、空格换连字符 —— **改 README 里这几个标题就会把
    /// 这里的链接打断**(页面照常打开、只是不跳到那一节,肉眼看不出来),selftest contracts 组有闸。
    public static func usageNoticeURL(language: String) -> URL {
        var components = URLComponents(string: repo)!
        let lang = language.lowercased()
        if lang.hasPrefix("zh") {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.zh-CN.md"
            components.fragment = "许可与版权说明"
        } else if lang == "ja" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.ja.md"
            components.fragment = "ライセンスと著作権"
        } else if lang == "ko" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.ko.md"
            components.fragment = "라이선스-및-저작권"
        } else if lang == "es" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.es.md"
            components.fragment = "licencia-y-derechos-de-autor"
        } else if lang == "fr" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.fr.md"
            components.fragment = "licence-et-droits-dauteur"
        } else if lang == "de" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.de.md"
            components.fragment = "lizenz-und-urheberrecht"
        } else if lang == "it" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.it.md"
            components.fragment = "licenza-e-diritti-dautore"
        } else if lang == "pt-br" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.pt-BR.md"
            components.fragment = "licença-e-direitos-autorais"
        } else if lang == "vi" {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.vi.md"
            components.fragment = "giấy-phép-và-bản-quyền"
        } else {
            components.path = "/Yudaotor/lyrimuse/blob/main/README.md"
            components.fragment = "license-and-copyright"
        }
        return components.url!
    }
}

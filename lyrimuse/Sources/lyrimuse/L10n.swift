import Foundation

// 本地化查找——不用 SwiftUI Text(_:LocalizedStringKey) 自带的自动语言协商,原因是一个
// 坑:纯用 `swift build`(没装完整 Xcode)编译时,SwiftPM 打包 .lproj 资源会把目录名
// 强制转小写(源码里写 zh-Hans.lproj,打包出来的 Bundle 里变成 zh-hans.lproj)。Apple
// 的 Bundle.preferredLocalizations 自动协商依赖精确匹配 BCP-47 语言标签的大小写,一变
// 小写协商就彻底失效——不管系统语言设成中文还是英文,自动协商永远只认到 "en"。绕开
// 办法:自己读 Locale.preferredLanguages 判断该用哪个语言,再手动定位到对应的 .lproj
// 目录、从这个具体路径构造 Bundle 直接查,不受目录名被打小写影响。
//
// 查找起点用 `Bundle.main` 而不是 `Bundle.module`(SwiftPM 生成的资源包访问器)——
// 那个访问器只认两个位置:`.app` 包根目录(故意不放东西进去,放了会导致 codesign 报
// "unsealed contents present in the bundle root"直接拒签,见 build.sh)和**写死指向
// 开发机的绝对路径**,在别的机器上两条路径都失效,`Bundle.module` 会在第一次被访问时
// 直接 `Swift.fatalError`(不可捕获),意味着别人的机器打开这个 App 几乎必崩。改成
// `Bundle.main` 后,`.lproj` 目录直接放在 `Contents/Resources/` 下(build.sh 里的拷贝
// 步骤)——这是 Apple 原生支持、不依赖任何机器的标准位置。
//
// 目前只做中/英两档:preferredLanguages 第一项以 "zh" 开头就用中文包,否则退到英文包。
// 要支持更多语言:①在 Resources/ 下加 `<lang>.lproj/Localizable.strings`(文件名小写,
// 跟打包出来的实际目录名一致);②在 `current` 里加一条判断分支返回对应目录名。查找/
// 兜底逻辑(bundle/t(_:))不用改。
enum L10n {
    // current/bundle 每次读都重新解析,不用 `static let` 一次性缓存——否则运行期切换
    // 语言不会立刻生效,得强制重启 App。这里故意不 import AppSettings.shared 来读这个
    // 手动覆盖值:AppSettings 是 `@MainActor` 单例,L10n 是给任何上下文调用的纯查找
    // 工具,不该反过来背上 actor 隔离;两处各自独立读写同一个 UserDefaults key
    // (np:appLanguage,AppSettings.swift 的 Keys.appLanguage 那份负责持久化+驱动
    // Picker,这里只读),字符串必须保持一致但没有编译期耦合。
    private static let languageOverrideKey = "np:appLanguage"

    // "system"(跟随系统,默认)/"zh-hans"/"en"。zh-hans.lproj 是这个项目的开发语言
    // (源码里所有字符串字面量本来就是简体中文),所以系统语言没匹配到已知前缀时,兜底
    // 也应该退回中文而不是英文——保证在没有对应语言包的系统语言下,至少还是能读懂的
    // 原文,不会突然冒出一句读不懂的英文兜底。
    static var current: String {
        let override = UserDefaults.standard.string(forKey: languageOverrideKey) ?? "system"
        if override == "en" || override == "zh-hans" { return override }
        let preferred = Locale.preferredLanguages.first ?? "zh-hans"
        return preferred.lowercased().hasPrefix("en") ? "en" : "zh-hans"
    }

    // 轻量缓存——只在 current 真的变化时才重新构造 Bundle(path:),避免每次 L10n.t(_:)
    // 调用都重新命中磁盘路径查找(一次界面渲染里同一个 View 常常连续调好几十次)。语言
    // 没变时直接复用上一次解析好的 Bundle,观感上跟改动前的 `static let` 版本一样便宜。
    private static var cached: (lang: String, bundle: Bundle)?

    private static var bundle: Bundle {
        let lang = current
        if let cached, cached.lang == lang { return cached.bundle }
        let resolved: Bundle
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            resolved = b
        } else {
            resolved = Bundle.main
        }
        cached = (lang, resolved)
        return resolved
    }

    // 找不到对应 key 时直接回退显示 key 本身(也就是原始中文文案)——不会崩溃、也不会
    // 显示空白,只是没翻译成目标语言,方便一眼看出漏翻了哪一条。
    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

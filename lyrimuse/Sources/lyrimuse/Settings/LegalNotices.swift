import AppKit
import Foundation
import LyrimuseCore

/// 「使用与版权说明」与「第三方许可」两个入口的打开动作(2026-09-03 加)。链接怎么拼见
/// `LegalNoticeLinks`(LyrimuseCore,纯判断);这里只负责 NSWorkspace 那一步。
///
/// 第三方许可证全文随包分发:build.sh 把仓库根的 THIRD_PARTY_LICENSES 拷进 Contents/Resources/
/// (BSD/MIT 的二进制分发条款要求随附版权声明与许可证文本)。此前这个文件一直在包里,但 App 里没有
/// 任何入口能打开它 —— "随附了却没人找得到"等于没附。优先打开包里那份(离线也能看);文件没有
/// 扩展名,LaunchServices 找不到默认打开方式,所以直接指定 TextEdit;`swift run` 这类没有包资源的
/// 开发态、或 TextEdit 不在 / 打不开时,退到 GitHub 上同一个文件。
enum LegalNotices {
    static var usageNoticeURL: URL { LegalNoticeLinks.usageNoticeURL(language: L10n.current) }

    /// 包内那份 THIRD_PARTY_LICENSES;开发态(没有 .app 包)为 nil。
    static var bundledThirdPartyLicenses: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: nil)
    }

    static func openUsageNotice() {
        NSWorkspace.shared.open(usageNoticeURL)
    }

    static func openLicense() {
        NSWorkspace.shared.open(LegalNoticeLinks.licenseOnGitHub)
    }

    static func openThirdPartyLicenses() {
        guard let file = bundledThirdPartyLicenses,
              let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(LegalNoticeLinks.thirdPartyLicensesOnGitHub)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: textEdit,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(LegalNoticeLinks.thirdPartyLicensesOnGitHub)
            }
        }
    }
}

import AppKit
import LyrimuseCore
import SwiftUI

/// 「歌词引擎」卡片上的一段说明:引擎要写的位置有哪些不归当前用户或写不进,附一个「复制修复命令」按钮。
/// 结论来自 `HomeFolderAccess`;改成需要管理员密码的命令要用户自己在终端里跑,App 不代为提权。
struct EngineFolderAccessNote: View {
    let findings: [HomeFolderAccess.Finding]
    @State private var copied = false

    var body: some View {
        Text(L10n.t("以下位置 Lyrimuse 无法写入，歌词引擎因此无法启动："))
        ForEach(findings, id: \.path) { finding in
            Text(Self.describe(finding))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
        Text(L10n.t("点按「复制修复命令」，打开「终端」，粘贴后按回车，按提示输入开机密码（输入时不显示字符），然后再点按「启用」"))
        Button(copied ? L10n.t("已复制") : L10n.t("复制修复命令")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(HomeFolderAccess.fixCommand(for: findings), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        }
    }

    private static func describe(_ finding: HomeFolderAccess.Finding) -> String {
        let path = HomeFolderAccess.displayPath(finding.path)
        switch finding.problem {
        case .ownedBy(let owner): return String(format: L10n.t("%@（属于 %@）"), path, owner)
        case .notWritable: return String(format: L10n.t("%@（没有写入权限）"), path)
        case .writableByOthers: return String(format: L10n.t("%@（其他用户也可修改，系统拒绝加载）"), path)
        }
    }
}

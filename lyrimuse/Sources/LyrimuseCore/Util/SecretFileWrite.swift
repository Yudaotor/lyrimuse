import Foundation
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "secret-file")

public extension Data {
    /// 原子写入,并把文件权限收紧到 `0600`(只有属主可读写)。**任何含凭据的文件都该走这个**,
    /// 而不是裸的 `write(to:options:.atomic)`。
    ///
    /// 为什么不能只靠 `.atomic`:原子写入的做法是先写临时文件再 rename 顶替,落地的是一个
    /// **新** inode,权限取当时的 umask —— 本机实测默认是 `0644`,也就是同机其他用户可读。
    /// macOS 给每个本地账号默认 gid=20(staff),而家目录是 `drwxr-x---` group=staff,组位
    /// 是通的,所以"同一台 Mac 上的第二个非管理员账号"确实能读到。同仓 Go 侧
    /// (`musixmatch.go` 写 token 缓存)早就用的是 0600,Swift 这边一直没跟上。
    ///
    /// 别把它当防线,它只挡住上面那一种情况。真正高频的泄密途径是**文件被整个外传**
    /// (贴进 issue、提交进 dotfiles、同步进共享盘),那种情况下权限位毫无作用 —— 那条线
    /// 归 `LogRedactor`(日志出口脱敏)和导出前的那句警告文案管。至于"任何以当前用户身份
    /// 运行的进程"(你装的任意 CLI、npm postinstall),权限位同样拦不住。
    ///
    /// 权限设置失败只记日志、不抛错:文件本身已经写成功了,为了权限没收紧就把整个保存
    /// 操作判失败、让用户以为配置没存上,是更糟的结果。
    func writeSecurely(to url: URL) throws {
        try write(to: url, options: .atomic)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            logger.error("could not tighten permissions on \(url.lastPathComponent, privacy: .public) — \(String(describing: error), privacy: .public)")
        }
    }
}

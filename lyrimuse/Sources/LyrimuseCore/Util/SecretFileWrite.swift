import Foundation
import OSLog

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "secret-file")

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
    /// 不能先 `.atomic` 写完再 chmod:那样新文件先按 umask 落成 0644,到 chmod 之前那一小段里同机其他账号
    /// 读得到。这里临时文件用 `open(O_CREAT|O_EXCL, 0600)` 建,一出生就只有属主可读写,写完再 `rename` 顶替
    /// 目标 —— rename 是原子的,顶替后的 inode 就是这个 0600 的临时文件。
    func writeSecurely(to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: self)
            try handle.synchronize()
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            logger.error("secure write of \(url.lastPathComponent, privacy: .public) failed — \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

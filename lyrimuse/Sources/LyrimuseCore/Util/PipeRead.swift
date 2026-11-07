import Darwin
import Foundation

/// 读管道 / 文件句柄,出错不抛 Objective-C 异常。`FileHandle` 的 `availableData`、`readDataToEndOfFile()` 遇到读错误
/// (EBADF、EIO)抛的是 `NSFileHandleOperationException`,Swift 接不住:后台线程上直接终止进程,主线程上被 AppKit 吞掉后
/// 留下坏掉的并发运行时状态(15 章决策 104)。这里一律按「读到结尾」处理。见 15 章决策 105。
public enum PipeRead {
    /// 现在能读到的一段(同 `availableData`):有数据返回数据,结尾或出错返回空。用在 `readabilityHandler` 和读到空为止的循环里。
    /// 传描述符,不传句柄:句柄关掉之后连读它的 `fileDescriptor` 也抛同一个异常。描述符在装回调 / 进循环之前、句柄还开着时取好。
    public static func chunk(fd: Int32, maxLength: Int = 65536) -> Data {
        guard fd >= 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxLength) }
            if n > 0 { return Data(buffer[0 ..< n]) }
            if n < 0, errno == EINTR { continue }
            return Data()
        }
    }

    /// 读到结尾(同 `readDataToEndOfFile()`);出错时返回已读到的部分为空。
    public static func toEnd(_ handle: FileHandle) -> Data {
        (try? handle.readToEnd()) ?? Data()
    }
}

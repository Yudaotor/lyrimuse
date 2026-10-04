import Foundation

/// 盯一个目录:里面的条目一变(新建、删除、改名 —— 原子写就是临时文件改名)就在 `queue` 上调一次 `onChange`。
/// 只盯目录项,不盯文件内容:原地改写一个已有文件不会触发。目录本身被删或挪走之后这个描述符就盯不到新目录了,
/// 调一次 `onGone` 并停下,由调用方决定退回轮询还是重建。
public final class DirectoryChangeWatcher {
    private let source: DispatchSourceFileSystemObject

    /// 目录打不开(不存在、没权限)时返回 nil。
    public init?(directory: URL, queue: DispatchQueue, onChange: @escaping () -> Void, onGone: @escaping () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                source.cancel()
                onGone()
            } else {
                onChange()
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

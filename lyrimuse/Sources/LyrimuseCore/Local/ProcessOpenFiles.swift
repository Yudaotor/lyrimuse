import Darwin

/// 一个进程此刻打开着的文件路径(libproc,同一用户的进程不需要额外权限,跟 `lsof` 同一来源)。
/// 用处:放本地文件、又不往系统里报歌手专辑的播放器(reAMP),按它的进程号找到正在放的那个文件读标签(`PlayerTitleSplit`)。
public enum ProcessOpenFiles {
    /// 打开着的普通文件路径,按文件描述符顺序。进程不存在或读不到时为空。
    public static func paths(pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                return String(cString: base)
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }
}

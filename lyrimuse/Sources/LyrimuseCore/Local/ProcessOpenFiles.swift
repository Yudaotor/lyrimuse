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

    /// 正在监听的 TCP 端口(本机字节序),按文件描述符顺序。进程不存在或读不到时为空。
    /// 用处:Plexamp 的本机播放器接口优先开在 32500,被占时换一个随机端口(`PlexampPlayerAPI`)。
    public static func listeningTCPPorts(pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return [] }
        var out: [Int] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0, !out.contains(port) { out.append(port) }
        }
        return out
    }

    /// 这个进程的直接子进程。读不到时为空。
    public static func childPIDs(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(buffer.prefix(Int(n))).filter { $0 > 0 }
    }
}

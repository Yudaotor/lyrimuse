import Darwin
import Foundation

/// 默认钥匙串(保险箱条目所在的登录钥匙串)锁没锁,查的时候不弹框。锁着时 `security` 取值、写入、删除都会让系统弹出
/// 要钥匙串密码的框,超时被结束后下一次又弹;所以 `KeychainCLI` 起 `security` 之前先问这里,锁着就当读不出、不起子进程。
/// 引擎不开 cgo、查不了,App 把「锁着」写进数据目录的提示文件(`hintFileName`,带 App 的 pid),引擎看到且那个进程还在就不去读。
/// 见 15 章决策 73。
public enum KeychainLock {
    public static let hintFileName = "lyrimuse-keychain-locked.json"

    struct Hint: Codable, Equatable {
        var pid: Int32
    }

    /// 锁着 true、没锁 false、查不了 nil。`SecKeychainGetStatus` 从 macOS 10.10 起标了弃用、仍然导出,按名字取:
    /// 哪天取不到就是 nil,调用方照旧直接起 `security`。
    public static func isDefaultKeychainLocked() -> Bool? {
        typealias GetStatus = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>) -> Int32
        guard let framework = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD)
                ?? dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(framework, "SecKeychainGetStatus") else { return nil }
        var status: UInt32 = 0
        guard unsafeBitCast(symbol, to: GetStatus.self)(nil, &status) == 0 else { return nil }
        // kSecUnlockStateStatus
        return status & 1 == 0
    }

    /// 查一次锁状态并记进 `dir` 里的提示文件,返回锁没锁。查不了按没锁算(跟以前一样直接起 `security`)。
    @discardableResult
    public static func check(hintIn dir: URL) -> Bool {
        let locked = isDefaultKeychainLocked() == true
        record(locked: locked, hintIn: dir)
        return locked
    }

    /// 锁着:提示文件写成本进程的 pid(已经是就不写);没锁:有提示文件就删掉。
    public static func record(locked: Bool, hintIn dir: URL, pid: Int32 = getpid()) {
        let url = dir.appendingPathComponent(hintFileName)
        if locked {
            guard FileIO.decodeJSON(Hint.self, from: url) != Hint(pid: pid),
                  let data = try? JSONEncoder().encode(Hint(pid: pid)) else { return }
            _ = FileIO.write(data, to: url)
        } else if StorageLayout.exists(url) {
            _ = FileIO.remove(url)
        }
    }
}

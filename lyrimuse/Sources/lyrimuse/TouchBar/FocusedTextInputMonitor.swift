import AppKit
import ApplicationServices
import LyrimuseCore

/// 前台 App 的键盘焦点在不在输入框里(触控栏「输入时收起」,见 17 章决策 59)。
///
/// 盯前台 App 的「焦点元素变了」「焦点窗口变了」两个辅助功能通知,一变就读焦点元素的角色交给 `TextInputFocus` 判;
/// 前台换了 App 就改盯新的那个。辅助功能的调用会卡在没响应的 App 上,全放在自己的线程里做、每次查询最多等
/// `messagingTimeout` 秒,结果切回主线程报,同一个值不重复报。没有辅助功能权限时报 false,前台下一次换 App 时再试;
/// 本 App 自己在前台时报 false。
final class FocusedTextInputMonitor {
    static let messagingTimeout: Float = 0.25

    private let worker: Worker
    private var activationObserver: NSObjectProtocol?

    /// `onChange` 在主线程上调。
    init(onChange: @escaping (_ isTextInput: Bool, _ role: String?) -> Void) {
        worker = Worker(report: { value, role in DispatchQueue.main.async { onChange(value, role) } })
        worker.start()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [worker] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            worker.perform { worker.watch(pid: pid) }
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        worker.perform { [worker] in worker.watch(pid: pid) }
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        worker.stop()
    }

    /// 自己那条线程:辅助功能观察者挂在它的 run loop 上,所有辅助功能状态只在这条线程上读写。
    fileprivate final class Worker {
        private let report: (Bool, String?) -> Void
        private var runLoop: CFRunLoop?
        private var observer: AXObserver?
        private var app: AXUIElement?
        private var last: (value: Bool, role: String?)?

        init(report: @escaping (Bool, String?) -> Void) {
            self.report = report
        }

        func start() {
            let ready = DispatchSemaphore(value: 0)
            let thread = Thread { [self] in
                runLoop = CFRunLoopGetCurrent()
                // 没有输入源的 run loop 一跑就退:挂一个不会到点的定时器撑着。
                let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
                CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
                ready.signal()
                CFRunLoopRun()
            }
            thread.name = "lyrimuse.focused-text-input"
            thread.qualityOfService = .userInitiated
            thread.start()
            ready.wait()
        }

        func perform(_ block: @escaping () -> Void) {
            guard let runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
            CFRunLoopWakeUp(runLoop)
        }

        func stop() {
            perform { [self] in
                detach()
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
        }

        func watch(pid: pid_t?) {
            detach()
            guard let pid, pid != getpid(), AXIsProcessTrusted() else {
                send(false, role: nil)
                return
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, FocusedTextInputMonitor.messagingTimeout)
            var created: AXObserver?
            guard AXObserverCreate(pid, focusChanged, &created) == .success, let observer = created else {
                send(false, role: nil)
                return
            }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
                _ = AXObserverAddNotification(observer, app, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.observer = observer
            self.app = app
            read()
        }

        func read() {
            guard let app else { return }
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
            else {
                send(false, role: nil)
                return
            }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, FocusedTextInputMonitor.messagingTimeout)
            let role = string(element, kAXRoleAttribute)
            let subrole = string(element, kAXSubroleAttribute)
            send(TextInputFocus.isTextInput(role: role, subrole: subrole), role: role)
        }

        private func detach() {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            app = nil
        }

        private func send(_ value: Bool, role: String?) {
            guard last?.value != value else { return }
            last = (value, role)
            report(value, role)
        }

        private func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
    }
}

/// 辅助功能观察者的回调(C 函数指针,不能捕获):`refcon` 是挂上去的那个 `Worker`,在它的线程上调。
private let focusChanged: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<FocusedTextInputMonitor.Worker>.fromOpaque(refcon).takeUnretainedValue().read()
}

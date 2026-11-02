import Foundation
import ObjectiveC
import os

/// 主线程上被 AppKit 吞掉的 Objective-C 异常的守卫。
///
/// 异常从主线程正在跑的 Swift 并发任务里往外抛、被 `-[NSApplication nextEventMatchingMask:…]` 的 `@catch` 接住时,
/// 并发运行时记「当前任务 / 当前执行器」的线程局部状态不会复位,还指着已经退掉的栈帧。之后任何一处
/// `MainActor.assumeIsolated` 或编译器插的隔离检查读到它都会段错误,崩溃栈落在不相干的计时器里,看不出是谁抛的。
///
/// 这里在主线程 run loop 每轮休眠前查一次:此刻调用栈里没有并发运行时的帧(不在任何任务里),线程上却还挂着任务,
/// 就是状态已坏。有记下的主线程异常时,把它交给一条新线程重抛,进程以未捕获异常终止,崩溃报告的
/// `lastExceptionBacktrace` 就是原来抛异常的位置;没有就只记一行日志。见 15 章决策 104。
///
/// 预处理器和观察者两个回调都不能带主线程隔离:编译器会给它们插隔离检查,检查本身就读那份坏掉的状态。
public enum SwallowedExceptionGuard {
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "exception-guard")

    /// 只在主线程上读写。
    nonisolated(unsafe) private static var lastMainThreadException: NSException?
    nonisolated(unsafe) private static var previousPreprocessor: objc_exception_preprocessor?
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var reportedWithoutException = false

    /// 进程入口在主线程上调一次。
    public static func install() {
        guard pthread_main_np() != 0, !installed else { return }
        installed = true
        previousPreprocessor = objc_setExceptionPreprocessor { thrown in
            if pthread_main_np() != 0, let exception = thrown as? NSException {
                SwallowedExceptionGuard.lastMainThreadException = exception
            }
            return SwallowedExceptionGuard.previousPreprocessor.map { $0(thrown) } ?? thrown
        }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            SwallowedExceptionGuard.check()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// 线程上挂着任务、调用栈里却没有并发运行时的帧。任务里起的嵌套 run loop(任务里调 `runModal`、弹菜单)栈里有那些帧,不算。
    public static func taskLeftOnCurrentThread() -> Bool {
        withUnsafeCurrentTask { $0 != nil } && !callStackRunsConcurrencyJob()
    }

    static func callStackRunsConcurrencyJob() -> Bool {
        Thread.callStackReturnAddresses.contains { address in
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: address.uintValue),
                  dladdr(pointer, &info) != 0, let file = info.dli_fname else { return false }
            return String(cString: file).hasSuffix("/libswift_Concurrency.dylib")
        }
    }

    private static func check() {
        guard taskLeftOnCurrentThread() else { return }
        guard let exception = lastMainThreadException else {
            if !reportedWithoutException {
                reportedWithoutException = true
                logger.fault("exception guard: main thread still carries a Swift task outside any job, no exception recorded")
            }
            return
        }
        logger.fault("exception guard: main thread still carries a Swift task after \(exception.name.rawValue, privacy: .public) was caught by the run loop, terminating with it")
        Thread.detachNewThread { exception.raise() }
        while true { pause() }
    }
}

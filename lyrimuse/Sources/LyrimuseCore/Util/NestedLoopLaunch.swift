import Foundation

/// 起嵌套事件循环(`runModal`、同步弹出的菜单)的地方用它推到下一轮主 run loop。
///
/// 主队列是串行的:在主队列块(`DispatchQueue.main.async` / `asyncAfter`、`OperationQueue.main`)或主 actor 的 Task 里
/// 直接起嵌套循环,循环开着多久,排在后面的主队列块和主 actor 任务就停多久。这里用 `.common` 模式的一次性定时器,
/// 回调不占主队列,嵌套循环开着期间主队列照常执行;菜单跟踪、模态面板开着时 `.common` 定时器也触发。
/// 别换成 `DispatchQueue.main.async` 或 `Task { @MainActor in }`(14 章决策 201)。
public enum NestedLoopLaunch {
    /// 下一轮主 run loop 在定时器回调里执行 `body`。哪个线程调都行。
    public static func nextTurn(_ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 主 actor 的 Task 里用:挂起,等 `body` 在下一轮主 run loop 的定时器回调里跑完,返回它的结果。
    @MainActor
    public static func run<T>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            nextTurn { continuation.resume(returning: body()) }
        }
    }
}

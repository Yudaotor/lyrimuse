import CoreGraphics
import Foundation

/// 滚轮兜底转发那次判定,能不能被同一次滚动手势里的后续事件复用。
///
/// ## 为什么需要缓存这个判定(2026-09-02,真机 `sample` 抓栈坐实)
///
/// `AppDelegate.forwardScrollIfStranded` 是装在**全局滚轮监视器**里的:每个进到本 App 的
/// 滚轮事件都要先判一次"这一下本来有没有人会处理",而那个判断里有一句
/// `root?.hitTest(loc)` —— 抓到的主线程栈显示它下面是一整条
/// `-[NSThemeFrame _performHitTestForContext:]` → `NSHostingView.hitTest` →
/// `PlatformHitTestingManager.hitTest` → `MultiViewResponder.containsGlobalPoints` 的**深度
/// 递归**,等于把整个窗口的 SwiftUI 视图树走一遍。
///
/// 触控板惯性滚动每秒发几十到上百个事件,于是每秒就有几十到上百次全窗口递归命中测试压在
/// 主线程上。用户报的是「设置页 Last.fm 那一段往下滑就卡、严重时整个 App 无响应要强制
/// 退出」,两台机器都遇到;那份 sample 里这个函数占了主线程 **74/1439 个采样**。
///
/// ⚠️ 排查时曾经一路怀疑 Last.fm 的数据链路(冷缓存、逐行播放次数请求、封面兜底、简繁写法
/// 索引…),**全部是错的方向**。这跟 Last.fm 一点关系都没有,是个**全局的、任何窗口任何
/// 页面都在付的成本**,只是那一页最长最深、把它放大到了看得见。别再顺着数据层查。
///
/// ## 判据
///
/// 滚动手势期间指针本来就不动,所以"同一个窗口 + 指针没挪出容差 + 还没过期"就可以直接
/// 重放上次结论,不必重算。三条缺一不可:
/// - **窗口**变了必须重算(不同窗口的层级完全不同);
/// - **指针**挪出容差必须重算(挪到别的滚动区上了);
/// - **过期**必须重算(视图层级可能已经变形)。
///
/// 纯函数,不碰 AppKit —— 这样 selftest 能直接覆盖(真正的转发逻辑依赖 NSEvent/NSWindow,
/// 在无窗口环境里跑不起来)。
public enum ScrollForwardDecision {
    /// 判定结果的有效期。挑得比一次滚动手势短、比事件间隔长得多 —— 惯性滚动的事件间隔是
    /// 毫秒级,而视图层级在四分之一秒内变形的概率极低。
    public static let ttl: TimeInterval = 0.25
    /// 指针挪动超过这个距离(点)就重新判定。
    public static let slopPoints: CGFloat = 4

    public static func canReuse(cachedWindow: Int, cachedPoint: CGPoint, cachedAt: Date,
                                window: Int, point: CGPoint, now: Date,
                                ttl: TimeInterval = ttl,
                                slop: CGFloat = slopPoints) -> Bool {
        guard cachedWindow == window else { return false }
        let age = now.timeIntervalSince(cachedAt)
        guard age >= 0, age < ttl else { return false }
        return abs(point.x - cachedPoint.x) <= slop && abs(point.y - cachedPoint.y) <= slop
    }
}

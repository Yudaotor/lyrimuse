import Combine

/// 一扇显示面窗口摆没摆出来(没被 orderOut),由窗口控制器在 orderFront 之前置真、orderOut 之后置假。窄订阅代理按它停发
/// 换句才变的那几项(`Publisher.gated`):关掉的、自动收起的显示面换句时不再重求 body;摆出来之前同一拍补发最新一份,
/// 窗口上屏的第一帧就是当前句。不看遮挡:被挡住、锁屏时窗口仍在屏上,一露出来就是系统直接合成的那一帧,来不及补。
/// 见 05 章决策 157。
@MainActor
public final class SurfaceFeedGate {
    @Published public private(set) var isLive = true

    public init() {}

    public func set(_ live: Bool) {
        if isLive != live { isLive = live }
    }
}

extension Publisher where Failure == Never, Output: Equatable {
    /// 显示面窄订阅代理里换句才变的那一项:`live` 为假时不发,翻回真那一刻补发最新的值;跟已经发过的一样就不发。
    @MainActor
    public func gated<Root: AnyObject>(by live: some Publisher<Bool, Never>, assign key: ReferenceWritableKeyPath<Root, Output>,
                                       on root: Root) -> AnyCancellable {
        combineLatest(live).filter(\.1).map(\.0).removeDuplicates()
            .sink { [weak root] in root?[keyPath: key] = $0 }
    }
}

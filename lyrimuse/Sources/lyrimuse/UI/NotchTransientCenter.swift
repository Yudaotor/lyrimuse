import Foundation
import SwiftUI

// 灵动岛上短暂盖住歌词行的一条提示("歌词 +0.5s""音量 40%")。
//
// 为什么需要一个"中心"而不是各处自己 @State 一个布尔加 DispatchQueue.asyncAfter:
// 这类提示天然是**可重入**的 —— 用户会连按三下偏移快捷键。各自计时的写法下,第一次的
// 计时器到点就把第三次的提示也一起关掉了(经典的 "cancel-rearm" 缺失)。这里每次 show
// 都先取消上一个待执行的隐藏任务再挂一个新的,连按多少次都以最后一次为准。
//
// ⚠️ Task.sleep 被取消时抛 CancellationError,`try?` 会把它吞成 nil 然后继续往下执行 ——
// 也就是说**光靠 try? 挡不住被取消的任务去清空 banner**,清空前必须再查一次
// Task.isCancelled。这正是上面那个连按场景真正会踩的那一脚。
@MainActor
final class NotchTransientCenter: ObservableObject {
    static let shared = NotchTransientCenter()

    struct Banner: Equatable {
        /// SF Symbol 名。
        var icon: String
        var text: String
        /// 0...1;给 nil 就不画那根细条(纯文字提示用)。
        var progress: Double?
    }

    @Published private(set) var banner: Banner?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ banner: Banner, for duration: TimeInterval = 1.4) {
        self.banner = banner
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}

/// 提示条本身。刻意跟歌词行同高、同一套排版重量,这样它盖上来/退下去时卡片不会变形。
///
/// 图标、文字、进度条全部走 tint(= 调用方传进来的 accentOrWhite),不留写死的白 ——
/// 否则「跟随封面取色」开着时,提示条盖上来的那一瞬间颜色会跟它顶替掉的歌词行对不上。
struct NotchTransientRow: View {
    let banner: NotchTransientCenter.Banner
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                // 图标宽度随符号变化(speaker.slash 比 speaker.wave.2 窄),不钉死宽度的话
                // 音量从 0 拖到 100 的过程中文字会左右挪。
                .frame(width: 16)
            Text(banner.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1)
            if let progress = banner.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.18))
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: proxy.size.width * min(1, max(0, progress)))
                    }
                }
                .frame(height: 3)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
    }
}

import SwiftUI

/// 设置窗口底部的「应用到后台服务」状态条(2026-09-05,借鉴清单 #51)。平时不渲染。
///
/// 功能开关与账号凭据都是「改了立刻保存」:写盘 + 去抖重启 collector。功能开关的调用点有 20 多处、全部
/// `Task { await features.save() }` 丢弃返回值,所以 FeatureSettingsStore.lastError 一直没人读——开关翻了、
/// 文件也写了,collector 却没重启,界面上看不出来(14 章决策 8 说的正是这类信息)。这里用一条浮在 detail 列底部的
/// 状态条一处覆盖全部调用点,不逐卡挂、不改调用点。三种状态按优先级:
///   1. 任一 Store 的 lastError 非空 → 橙色:原因 + 「重试」(重试 = 再走一次 save(),幂等)+ 关闭;
///   2. 重启排队 / 进行中 → 一行小字「正在应用到后台服务…」(0.5s 去抖 + 最多 3s 确认,撞上 launchd 节流可到 10s);
///   3. 上次保存因后台服务被主动停用而没重启 → 中性提示,服务一启用就消失。
/// 用 overlay 而不是 safeAreaInset:这条会随每次拨开关出现又消失,inset 会让整页内容上下跳;顶部那条损坏横幅是
/// 持久态才用 inset。
struct CollectorApplyStatusBar: View {
    @ObservedObject private var features = FeatureSettingsStore.shared
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var coordinator = CollectorRestartCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var retrying = false

    private enum Phase: Equatable {
        case failed(String)
        case applying
        case pendingServiceEnable
    }

    private var phase: Phase? {
        if let error = features.lastError ?? config.lastError { return .failed(error) }
        if coordinator.isRestarting { return .applying }
        if (features.pendingUntilServiceEnabled || config.pendingUntilServiceEnabled) && !settings.collectorServiceEnabled {
            return .pendingServiceEnable
        }
        return nil
    }

    var body: some View {
        Group {
            switch phase {
            case .failed(let error):
                strip {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        // 锁拉丁语区,理由同 SettingsRow 里那处注释(SF Symbols 的部分符号有 CJK 变体)。
                        .environment(\.locale, Locale(identifier: "en"))
                    Text(error)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L10n.t("重试")) { retry() }
                        .disabled(retrying || coordinator.isRestarting)
                    dismissButton
                }
            case .applying:
                strip {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在应用到后台服务…"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            case .pendingServiceEnable:
                strip {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                    Text(L10n.t("后台采集服务已停用，改动会在下次启用时生效"))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    dismissButton
                }
            case nil:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: phase)
    }

    private var dismissButton: some View {
        Button {
            features.clearApplyStatus()
            config.clearApplyStatus()
        } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel(L10n.t("关闭"))
    }

    @ViewBuilder
    private func strip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.system(size: 12))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .transition(.opacity)
    }

    private func retry() {
        retrying = true
        Task {
            // 哪个 Store 报的错就重走哪个 save():再落一次盘(幂等,顺带把途中改的开关带上)+ 再踢一次重启。
            // 两个同时失败时并发发起,让 CollectorRestartCoordinator 把两次请求合并成一次重启。
            let featuresFailed = features.lastError != nil
            let configFailed = config.lastError != nil
            async let f: Bool = featuresFailed ? features.save() : true
            async let c: Bool = configFailed ? config.save() : true
            _ = await (f, c)
            retrying = false
        }
    }
}

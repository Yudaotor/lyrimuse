import AppKit
import Sparkle

/// Sparkle 的自定义用户界面驱动(2026-09-12,用户拍板把更新做成系统「软件更新」那种页面,见 14 章决策 #25)。
///
/// Sparkle 2 允许用 `SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)` 接管**全部**更新界面:
/// 发现更新、下载进度、下完待装、安装中、失败,每一步都回调到这里,由我们在设置窗口的「软件更新」页里画,
/// 一个系统弹窗都不弹。改版前用的是 `SPUStandardUpdaterController`(Sparkle 自带的那套模态窗)。
///
/// 这个类只做**转发**:把每个回调原样(连同 Sparkle 给的 reply / cancel 闭包)包成 `Event` 交给
/// `SparkleUpdaterManager`,状态机与页面逻辑都在那边;这里不持有任何状态。单独一个 NSObject 的理由同
/// `UpdaterDelegateBridge`:ObjC 协议要求 NSObject 子类,管理器不是。
///
/// `SPUUserDriver` 标了 NS_SWIFT_UI_ACTOR,所以整个类是 @MainActor,回调直接在主线程上进来;
/// 闭包也就都能安全地攥在 @MainActor 的管理器里、等用户在页面上点按钮再答。
@MainActor
final class SoftwareUpdateDriver: NSObject, SPUUserDriver {
    enum Event {
        /// 首次运行「要不要自动检查」的问询。我们不弹窗,按设置页那个开关的当前值答。
        case permissionRequest(reply: (SUUpdatePermissionResponse) -> Void)
        /// 用户发起的检查开始了;cancel 能中止。
        case userInitiatedCheck(cancel: () -> Void)
        /// 找到新版本。state.stage 说它还没下 / 已下好 / 已在装;reply 必须**且只能**答一次。
        case found(item: SUAppcastItem, state: SPUUserUpdateState, reply: (SPUUserUpdateChoice) -> Void)
        /// appcast 用 releaseNotesLink 外挂说明时,Sparkle 下回来的正文。
        case releaseNotes(SPUDownloadData)
        case releaseNotesFailed(any Error)
        /// 已是最新(error 里带着「为什么没更新」的说明,我们不用)。
        case notFound(any Error, acknowledge: () -> Void)
        case failed(any Error, acknowledge: () -> Void)
        case downloadStarted(cancel: () -> Void)
        case downloadExpectedLength(UInt64)
        case downloadReceived(UInt64)
        case extractionStarted
        case extractionProgress(Double)
        /// 下完解好,等一句「现在装还是退出时装」。
        case readyToInstall(reply: (SPUUserUpdateChoice) -> Void)
        /// 正在装;applicationTerminated=false 表示 App 还没退(被什么拦住了),retry 再试一次退出。
        case installing(applicationTerminated: Bool, retryTerminating: () -> Void)
        /// 重启后 Sparkle 报「上一版装好了」。
        case installedAndRelaunched(Bool, acknowledge: () -> Void)
        /// 这一轮会话结束,把进度 / 弹窗收掉。
        case dismissed
        /// Sparkle 要求把更新界面拉到前面(比如用户又点了一次「检查更新」而会话还在)。
        case focusRequested
    }

    var onEvent: ((Event) -> Void)?

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        onEvent?(.permissionRequest(reply: reply))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onEvent?(.userInitiatedCheck(cancel: cancellation))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onEvent?(.found(item: appcastItem, state: state, reply: reply))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        onEvent?(.releaseNotes(downloadData))
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        onEvent?(.releaseNotesFailed(error))
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onEvent?(.notFound(error, acknowledge: acknowledgement))
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onEvent?(.failed(error, acknowledge: acknowledgement))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        onEvent?(.downloadStarted(cancel: cancellation))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        onEvent?(.downloadExpectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        onEvent?(.downloadReceived(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        onEvent?(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onEvent?(.extractionProgress(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onEvent?(.readyToInstall(reply: reply))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        onEvent?(.installing(applicationTerminated: applicationTerminated, retryTerminating: retryTerminatingApplication))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        onEvent?(.installedAndRelaunched(relaunched, acknowledge: acknowledgement))
    }

    func dismissUpdateInstallation() {
        onEvent?(.dismissed)
    }

    func showUpdateInFocus() {
        onEvent?(.focusRequested)
    }
}

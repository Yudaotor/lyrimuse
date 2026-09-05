import Foundation

/// 版本号的纯逻辑:tag → 展示版本 / 构建号 / 大小比较。跟 `lyrimuse/scripts/build-version.sh` 是同一套映射的两种
/// 语言 —— 那份 shell 是**构建时的真源**(build.sh 写 Info.plist、release.yml 生成 appcast 都调它),这里是 App 运行时
/// (「接收测试版更新」挑最高版本)用的镜像;selftest update-channel 组拿一张表交叉校验两边逐字一致。
///
/// 为什么构建号要和展示版本分开、为什么正式版是 1000(2026-09-05):Sparkle 的 SUStandardVersionComparator 实测把
/// "-" 之后的全部忽略 —— "1.6.0-beta.1" 与 "1.6.0"、"beta.2" 与 "beta.1" 都判相等。所以 CFBundleShortVersionString
/// 保留 tag 原文给人看,CFBundleVersion / sparkle:version 用四段纯数字给 Sparkle 比:alpha N、beta 100+N、rc 500+N、
/// 正式 1000,三档预发布分区互不重叠且都压在正式版之下。老用户机上的三段 "1.5.0" 跟四段新号比到第二段就分出大小。
public struct ReleaseVersion: Equatable, Comparable, CustomStringConvertible {
    public enum PreKind: String, CaseIterable {
        case alpha, beta, rc
        /// 构建号第四段的分区起点。
        public var buildOffset: Int {
            switch self {
            case .alpha: return 0
            case .beta: return 100
            case .rc: return 500
            }
        }
        /// N 的上限:分区不能溢出到下一档。
        public var maxNumber: Int {
            switch self {
            case .alpha: return 99
            case .beta: return 399
            case .rc: return 499
            }
        }
    }

    public static let stableBuild = 1000

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let preKind: PreKind?
    /// 预发布编号(1 起);正式版为 0。
    public let preNumber: Int

    /// 认 "v1.6.0" / "1.6.0" / "v1.6.0-beta.2";两段、四段、后缀无编号、未知后缀、编号 0、带前导零一律 nil ——
    /// 跟 build-version.sh 的正则一字不差。
    public init?(tag: String) {
        var s = Substring(tag)
        if s.hasPrefix("v") { s.removeFirst() }
        let dash = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = dash[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy(Self.isCanonicalNumber) else { return nil }
        major = Int(core[0])!
        minor = Int(core[1])!
        patch = Int(core[2])!
        if dash.count == 1 {
            preKind = nil
            preNumber = 0
            return
        }
        let pre = dash[1].split(separator: ".", omittingEmptySubsequences: false)
        guard pre.count == 2, let kind = PreKind(rawValue: String(pre[0])),
              Self.isCanonicalNumber(pre[1]), let n = Int(pre[1]), n >= 1, n <= kind.maxNumber else { return nil }
        preKind = kind
        preNumber = n
    }

    /// 纯数字、非空、不带前导零(单个 0 除外)。
    private static func isCanonicalNumber(_ s: Substring) -> Bool {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return s == "0" || s.first != "0"
    }

    public var isPrerelease: Bool { preKind != nil }
    /// 构建号第四段。
    public var buildComponent: Int { preKind.map { $0.buildOffset + preNumber } ?? Self.stableBuild }
    /// 给人看的:tag 去掉 v。
    public var displayString: String {
        if let preKind { return "\(major).\(minor).\(patch)-\(preKind.rawValue).\(preNumber)" }
        return "\(major).\(minor).\(patch)"
    }
    /// 给 Sparkle 比的:CFBundleVersion / sparkle:version。
    public var buildNumberString: String { "\(major).\(minor).\(patch).\(buildComponent)" }
    public var description: String { displayString }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.buildComponent) < (rhs.major, rhs.minor, rhs.patch, rhs.buildComponent)
    }
}

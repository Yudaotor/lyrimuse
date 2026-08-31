import Foundation

/// 「跨语言歌名别名」自动发现的**证据门槛**——纯函数,配 selftest。
///
/// ## 为什么需要它(2026-08-30)
///
/// 自动发现原来的判据是「同一歌手 + duration **精确相等** + 候选唯一」。设计时对假阳性
/// 的估计写在注释里:"两首**毫秒级**同时长的不同歌",所以概率极小。
///
/// **那个前提不成立。** Last.fm 的 `track.getinfo` 返回的 duration 就是**整秒**(实测某台
/// 机器 908 条全是 ×1000,不是客户端截断的),精度比假设低 1000 倍。同一份数据实测:
/// 536 首里 **216 首(40%)** 与同歌手的另一首歌时长完全相同,陶喆名下光 255 秒就有 5 首。
/// "极小概率"实际是四成 —— duration 相等几乎不携带信息量。
///
/// 实际产出的错误(同一份数据):
///   - 宇多田ヒカル「Time」(专辑 BADモード, 2022)被判成「SAKURAドロップス」
///     (专辑 Deep River, 2002)—— 相隔 20 年的两首歌,只因都是 298 秒。
///   - 陶喆「I'm O.K.」与「Runaway」**双双**被判成《天天》(反向撞车,另见调用方的守卫)。
///
/// ## 判据是**非对称**的
///
/// 沿用这套机制既有的取舍(错合并比不合并更糟:错的账两首歌全错、且不易察觉;漏合并
/// 只是"暂时没发现",下次扫描还会再试):
///
///   - **mbid 都有且相同** ⇒ 放行。同一个 MusicBrainz recording,最强证据。
///   - **专辑名都有、且折叠后不同** ⇒ **否决**。
///   - 其余(专辑缺失 / 折叠后相同 / mbid 缺失) ⇒ 放行,退回 duration + 唯一性那两道。
///
/// ⚠️ 刻意**不**把"专辑相同"当作准入条件,只当否决信号:跨语言写法的专辑名本身也可能是
/// 两种文字(《橙月》vs "Orange Moon"),硬要求相同会把真别名一起挡掉。
public enum TitleAliasEvidence {
    /// 除 duration 之外的独立证据是否支持"这两条是同一首歌"。
    /// 空串 = 那一项 Last.fm 没给(不是"值为空"),按缺失处理。
    public static func agrees(mbidA: String, albumA: String,
                              mbidB: String, albumB: String) -> Bool {
        let ma = mbidA.trimmingCharacters(in: .whitespaces)
        let mb = mbidB.trimmingCharacters(in: .whitespaces)
        if !ma.isEmpty, ma == mb { return true }

        let aa = albumA.trimmingCharacters(in: .whitespaces)
        let ab = albumB.trimmingCharacters(in: .whitespaces)
        guard !aa.isEmpty, !ab.isEmpty else { return true } // 缺专辑:这一档给不出结论,放行
        // 用 foldTitle 比而不是裸字符串相等:那套折叠本来就是为"同一个东西的不同写法"
        // 设计的(繁简 / 全半角 / 目录学噪音),比裸比较靠谱得多。
        return PlayCountFold.foldTitle(aa) == PlayCountFold.foldTitle(ab)
    }
}

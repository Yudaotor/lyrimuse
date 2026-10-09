import AppKit
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "lyrics-external-edit")

/// 歌词窗口「用外部编辑器改歌词」(07 章决策 112)。
///
/// 不打开歌词目录里引擎导出的那份 .lrc:引擎随时会按缓存重写、删掉它,改它要到下次启动才导回缓存。这里给这首在
/// `lyrimuse-lyrics-editing/` 下写一份 .txt 工作副本,用打开纯文本的默认应用打开,每秒看一眼它变没变;编辑器存盘后
/// 按 `LyricsExternalEdit.decide` 套回去,经改动通道交给引擎存(同歌词管理「保存修改」)。一次编辑绑在打开时那首的
/// 缓存 key 上,换了歌照样存回那一首。会话只在内存里,App 退出就结束。
@MainActor
final class LyricsExternalEditor {
    static let shared = LyricsExternalEditor()

    static let directory = LyrimusePaths.configFile("lyrimuse-lyrics-editing")
    /// 每份工作副本上次写进去或套用过的那一份的指纹;打开时据此判断盘上那份能不能覆盖(`LyricsExternalEdit.fileAction`)。
    private static let stateURL = directory.appendingPathComponent(".lyrimuse-state.json")
    /// 比这大的不当歌词读。
    private static let maxBytes = 1 << 20

    private struct FileStamp: Equatable {
        let mtime: Date
        let size: Int
    }

    private struct Session {
        let key: String
        let artist: String
        let title: String
        let album: String
        let url: URL
        /// 摊开时(或上一次套用之后)这首的三块正文,存回来的修改对着它套。
        var base: LyricsExternalEdit.Content
        /// 写进文件的那一份,或者上一次套用过的那一份;文件内容跟它一样就没有新修改。
        var reference: String
        var seen: FileStamp?
        /// 刚交给引擎存了、读取器还没解到那一版:先不比对,解到了再把 base 换成存下来的那份。
        var awaitingRebase = false
        var applying = false
    }

    private var sessions: [String: Session] = [:]
    private var timer: Timer?
    private var notes: LyricsWindowActionNotes { .shared }

    private init() {}

    /// 给这首写好工作副本、交给编辑器。已经在编辑这首、歌词也没变过,就只把编辑器叫到前面。
    func open(artist: String, title: String, album: String) {
        guard !title.isEmpty else { return }
        let stored = EnrichCacheReader.storedEntry(artist: artist, title: title, album: album)
        if stored == nil, !EnrichCacheReader.isCurrent {
            // 歌词库正在重读(引擎刚写过、内存压力让出之后):查不到不代表这首没有记录,别给它摊一份空的。
            EnrichCacheReader.refreshIfNeeded()
            notes.post(.info, title: title, text: L10n.t("歌词库正在刷新，请稍后重试"))
            return
        }
        if let stored, !stored.complete {
            notes.post(.failure, title: title, text: L10n.t("暂时无法读取这首歌曲的歌词，请稍后重试"))
            return
        }
        let key = stored?.key ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let content = Self.content(stored)
        let fresh = LyricsExternalEdit.workingCopy(content, title: title, artist: artist, album: album)
        var setAside: String?

        if var session = sessions[key] {
            let exists = FileManager.default.fileExists(atPath: session.url.path)
            if !exists, session.awaitingRebase {
                // 刚存过、读取器还没解到新的一版:写回刚套用的那一份,base 等解到了再换。
                guard write(session.reference, to: session.url, title: title) else { return }
                session.seen = Self.stamp(session.url)
                sessions[key] = session
            } else if !exists || (!session.awaitingRebase && session.base != content) {
                // 文件没了,或者这首的歌词在这期间变过(重新匹配过、别处改过):换成现在这一份;
                // 文件里有还没套用的修改就先挪开另存。
                if exists, Self.readText(session.url) != session.reference {
                    guard let moved = self.setAside(session.url, title: title) else { return }
                    setAside = moved
                }
                guard write(fresh, to: session.url, title: title) else { return }
                session.base = content
                session.reference = fresh
                session.seen = Self.stamp(session.url)
                session.awaitingRebase = false
                sessions[key] = session
            }
            launch(session.url, title: title, mode: LyricsExternalEdit.mode(of: session.base), setAside: setAside)
            return
        }

        let url = Self.directory.appendingPathComponent(EnrichCacheKeys.sanitizeFilename(key) + ".txt")
        let exists = FileManager.default.fileExists(atPath: url.path)
        let existing = exists ? Self.readText(url) : nil
        // 读不出来的已有文件也算「别人的东西」,挪开,不覆盖。
        let action = exists && existing == nil
            ? LyricsExternalEdit.FileAction.setAsideThenWrite
            : LyricsExternalEdit.fileAction(existing: existing, fresh: fresh, recorded: Self.recordedFingerprints()[url.lastPathComponent])
        switch action {
        case .reuse:
            Self.record(fresh, for: url)
        case .write:
            guard write(fresh, to: url, title: title) else { return }
        case .setAsideThenWrite:
            guard let moved = self.setAside(url, title: title) else { return }
            setAside = moved
            guard write(fresh, to: url, title: title) else { return }
        }
        sessions[key] = Session(key: key, artist: artist, title: title, album: album, url: url,
                                base: content, reference: fresh, seen: Self.stamp(url))
        startTimer()
        launch(url, title: title, mode: LyricsExternalEdit.mode(of: content), setAside: setAside)
    }

    // MARK: - 打开编辑器

    private func launch(_ url: URL, title: String, mode: LyricsExternalEdit.Mode, setAside: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            notes.post(.failure, title: title, text: L10n.t("未找到可打开文本文件的应用"))
            return
        }
        let appName = FileManager.default.displayName(atPath: app.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                let notes = LyricsWindowActionNotes.shared
                if let failure {
                    logger.error("editor launch failed: \(failure, privacy: .public)")
                    notes.post(.failure, title: title, text: String(format: L10n.t("无法打开「%1$@」：%2$@"), appName, failure))
                    return
                }
                var lines: [String]
                switch mode {
                case .wordTimed:
                    lines = [String(format: L10n.t("已在「%@」中打开。逐字歌词仅修改文字，请勿改动每行开头的时间，保存后自动应用"), appName)]
                case .lineTimed:
                    lines = [String(format: L10n.t("已在「%@」中打开，保存后自动应用"), appName)]
                case .plainText, .empty:
                    lines = [String(format: L10n.t("已在「%@」中打开。保存后自动应用：带时间戳的内容存为同步歌词，不带时间戳的存为纯文本"), appName)]
                }
                if let setAside {
                    lines.append(String(format: L10n.t("上次已保存但未应用的内容已另存为「%@」"), setAside))
                }
                notes.post(setAside == nil ? .info : .warning, title: title, text: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - 盯文件、套回去

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { LyricsExternalEditor.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        for key in Array(sessions.keys) { check(key) }
    }

    private func check(_ key: String) {
        guard var session = sessions[key], !session.applying else { return }
        if session.awaitingRebase {
            guard EnrichCacheReader.isCurrent else {
                EnrichCacheReader.refreshIfNeeded()
                return
            }
            session.base = Self.content(EnrichCacheReader.storedEntry(forKey: key))
            session.awaitingRebase = false
            sessions[key] = session
        }
        // 文件暂时不在(有的编辑器存盘时先挪走原文件再写新的)就等下一拍。
        guard let stamp = Self.stamp(session.url), stamp != session.seen else { return }
        // 引擎刚写过、读取器还没解到:等它解完再比对。拿旧的一版比会误报变过,没改的译文、读音也会拿旧的补。
        guard EnrichCacheReader.isCurrent else {
            EnrichCacheReader.refreshIfNeeded()
            return
        }
        session.seen = stamp
        sessions[key] = session
        guard let data = FileIO.read(session.url) else { return }
        guard data.count <= Self.maxBytes else {
            notes.post(.warning, title: session.title, text: L10n.t("文件过大，不像是歌词，未保存"))
            return
        }
        guard let text = LyricsExternalEdit.text(from: data) else {
            notes.post(.failure, title: session.title, text: L10n.t("无法读取该文件（需保存为 UTF-8 文本），未保存"))
            return
        }
        guard text != session.reference else { return }
        let stored = EnrichCacheReader.storedEntry(forKey: key)
        if let stored, !stored.complete {
            notes.post(.failure, title: session.title, text: L10n.t("暂时无法读取这首歌曲的歌词，请稍后再次保存"))
            return
        }
        guard Self.content(stored) == session.base else {
            notes.post(.warning, title: session.title,
                       text: L10n.t("编辑期间这首歌曲的歌词已发生变化，本次未应用；再次编辑将打开最新版本"))
            return
        }
        apply(text, session: session, stored: stored)
    }

    private func apply(_ text: String, session: Session, stored: EnrichCacheReader.StoredEntry?) {
        let title = session.title
        switch LyricsExternalEdit.decide(edited: text, base: session.base) {
        case .unchanged:
            sessions[session.key]?.reference = text
            Self.record(text, for: session.url)
            notes.post(.info, title: title, text: L10n.t("无可保存的更改"))
        case .empty:
            notes.post(.warning, title: title, text: L10n.t("文件中尚无歌词，未保存"))
        case .missingTimestamps:
            notes.post(.warning, title: title, text: L10n.t("保存的歌词不含任何时间戳，未保存（否则会丢失原有时间轴）"))
        case let .word(result):
            var done = [L10n.t("已应用编辑器中的修改")]
            if result.estimatedLines > 0 {
                done.append(String(format: L10n.t("%@ 句为新增或修改了时间戳，已按字数分配逐字时间"), "\(result.estimatedLines)"))
            }
            if result.skippedLines > 0 {
                done.append(String(format: L10n.plural("%@ 行无时间戳，未写入逐字歌词", count: result.skippedLines), "\(result.skippedLines)"))
            }
            save(text, session: session, done: done, carriesOffsetTo: result.timingUnchanged ? (lyrics: result.lrc, yrc: result.yrc) : nil) {
                await EnrichCacheStore.shared.saveEdit(key: session.key, lyrics: result.lrc, tr: stored?.lyricsTr ?? "",
                                                       roma: stored?.lyricsRoma ?? "", yrc: result.yrc)
            }
        case let .lines(lyrics):
            let sameTimes = LyricsWordTimingEdit.sameLineTimes(session.base.lyrics, lyrics)
            save(text, session: session, done: [L10n.t("已应用编辑器中的修改")],
                 carriesOffsetTo: sameTimes ? (lyrics: lyrics, yrc: session.base.yrc) : nil) {
                await EnrichCacheStore.shared.saveEdit(key: session.key, lyrics: lyrics, tr: stored?.lyricsTr ?? "",
                                                       roma: stored?.lyricsRoma ?? "")
            }
        case let .plain(plain):
            save(text, session: session, done: [L10n.t("已保存为纯文本歌词，仅在歌词窗口中显示")], carriesOffsetTo: nil) {
                await EnrichCacheStore.shared.savePlainTextEdit(key: session.key, plainLyrics: plain, source: "")
            }
        }
    }

    /// 交给引擎存(跟歌词管理「保存修改」同一条改动通道:手改的标人工修正,译文、读音原样交回)。
    /// `carriesOffsetTo`:只改了字时新的正文和逐字,这首的单曲偏移搬过去。
    private func save(_ text: String, session: Session, done: [String], carriesOffsetTo new: (lyrics: String, yrc: String)?,
                      _ commit: @escaping @MainActor () async -> Bool) {
        sessions[session.key]?.applying = true
        Task {
            let saved = await commit()
            sessions[session.key]?.applying = false
            guard saved else {
                notes.post(.failure, title: session.title, text: L10n.t("保存失败，请重试"))
                return
            }
            if let new { carryOffset(session, to: new) }
            sessions[session.key]?.reference = text
            sessions[session.key]?.awaitingRebase = true
            Self.record(text, for: session.url)
            notes.post(.success, title: session.title, text: done.joined(separator: "\n"))
        }
    }

    /// 单曲偏移按正文指纹存:从旧正文的 key 搬到新正文下,新的下面已经有值就不动(同歌词管理 carryOffset)。
    private func carryOffset(_ session: Session, to new: (lyrics: String, yrc: String)) {
        let store = LyricsOffsetStore.shared
        let oldKey = LyricsOffsetStore.trackKey(artist: session.artist, title: session.title,
                                                lyrics: session.base.lyrics, lyricsYRC: session.base.yrc)
        let newKey = LyricsOffsetStore.trackKey(artist: session.artist, title: session.title, lyrics: new.lyrics, lyricsYRC: new.yrc)
        let ms = store.offset(forKey: oldKey)
        guard ms != 0, oldKey != newKey, store.offset(forKey: newKey) == 0 else { return }
        store.setOffset(0, forKey: oldKey, pinKey: "")
        store.setOffset(ms, forKey: newKey,
                        pinKey: EnrichCacheKeys.normalizedKey(artist: session.artist, title: session.title, album: session.album))
    }

    // MARK: - 文件

    private static func content(_ stored: EnrichCacheReader.StoredEntry?) -> LyricsExternalEdit.Content {
        guard let stored else { return LyricsExternalEdit.Content() }
        return LyricsExternalEdit.Content(lyrics: stored.lyrics, yrc: stored.lyricsYRC, plain: stored.plainLyrics)
    }

    private func write(_ text: String, to url: URL, title: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            // 文本编辑按这个扩展属性认编码,不带的话没有 BOM 的中文可能被猜成别的编码。
            _ = "utf-8;134217984".withCString { setxattr(url.path, "com.apple.TextEncoding", $0, strlen($0), 0, 0) }
            Self.record(text, for: url)
            return true
        } catch {
            logger.error("working copy write failed: \(error.localizedDescription, privacy: .public)")
            notes.post(.failure, title: title, text: String(format: L10n.t("无法写入歌词文件：%@"), error.localizedDescription))
            return false
        }
    }

    /// 盘上那份是存了还没套用的修改:改名另存成 `<名字>.<时间>.txt`,返回新文件名;改不了名就不往下写,免得盖掉。
    private func setAside(_ url: URL, title: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent + "." + formatter.string(from: Date()) + ".txt"
        do {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
            return name
        } catch {
            logger.error("working copy set-aside failed: \(error.localizedDescription, privacy: .public)")
            notes.post(.failure, title: title, text: String(format: L10n.t("无法写入歌词文件：%@"), error.localizedDescription))
            return nil
        }
    }

    private static func readText(_ url: URL) -> String? {
        FileIO.read(url).flatMap(LyricsExternalEdit.text(from:))
    }

    private static func stamp(_ url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(mtime: mtime, size: (attrs[.size] as? NSNumber)?.intValue ?? 0)
    }

    private static func recordedFingerprints() -> [String: String] {
        guard let data = FileIO.read(stateURL),
              let map = FileIO.decodeJSON([String: String].self, from: data, source: stateURL) else { return [:] }
        return map
    }

    private static func record(_ text: String, for url: URL) {
        var map = recordedFingerprints()
        map[url.lastPathComponent] = LyricsExternalEdit.fingerprint(text)
        guard let data = try? JSONEncoder().encode(map) else { return }
        FileIO.write(data, to: stateURL)
    }
}

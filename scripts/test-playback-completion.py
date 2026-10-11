#!/usr/bin/env python3
"""Replay the coordinator's actual completion/readback methods without GUI or players."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift"


def function(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


source = SOURCE.read_text()
toggle = function(source, "func userTogglePlayPause()")
readback = function(source, "private func updateSmoothedPlaying(")
program = r'''
import Foundation
@MainActor final class LocalPlaybackSource {
    static let shared = LocalPlaybackSource()
    var lastResolvedBundleID: String? = "qq"
}
@MainActor enum MusicPlaybackController {
    enum Command { case playPause }
    enum ControlRoute { case mediaControl, qqAccessibility(Command) }
    typealias Completion = @MainActor (ControlRoute?) -> Void
    static var normal = false
    static var pending: [Completion] = []
    static func playPause(completion: Completion? = nil) {
        guard let completion else { return }
        if normal { completion(.mediaControl) } else { pending.append(completion) }
    }
    static func finish(_ route: ControlRoute?) { pending.removeFirst()(route) }
}
@MainActor final class Coordinator {
    var isPlayingNow = false
    var isPlayingSmoothed = false
    private var stopGraceWork: DispatchWorkItem?
    private var optimisticReconcileWork: DispatchWorkItem?
    private static let stopGracePeriod: TimeInterval = 0.25
    func sample(_ playing: Bool) { isPlayingNow = playing; updateSmoothedPlaying(playing) }
''' + toggle + "\n" + readback + r'''
}
@MainActor func replay() {
    typealias C = MusicPlaybackController
    let qq = C.ControlRoute.qqAccessibility(.playPause)
    let resumed = Coordinator()
    resumed.userTogglePlayPause()
    resumed.sample(true)
    C.finish(qq)
    precondition(resumed.isPlayingSmoothed, "readback-before-success must stay playing")

    let paused = Coordinator()
    paused.sample(true)
    paused.userTogglePlayPause()
    paused.sample(false)
    C.finish(qq)
    precondition(!paused.isPlayingSmoothed, "known pause must not be reversed by completion")

    let late = Coordinator()
    late.userTogglePlayPause()
    C.finish(qq)
    precondition(!late.isPlayingSmoothed, "AX success is not confirmed playback")
    late.sample(true)
    precondition(late.isPlayingSmoothed, "later readback drives the deferred route")

    let rapid = Coordinator()
    rapid.sample(true)
    rapid.userTogglePlayPause(); rapid.userTogglePlayPause()
    rapid.sample(false); rapid.sample(true)
    C.finish(qq); C.finish(qq)
    precondition(rapid.isPlayingSmoothed, "two deferred successes must not reverse latest truth")

    let failed = Coordinator()
    failed.userTogglePlayPause(); C.finish(nil)
    precondition(!failed.isPlayingSmoothed, "failure must not flip the icon")

    let changed = Coordinator()
    changed.userTogglePlayPause()
    LocalPlaybackSource.shared.lastResolvedBundleID = "spotify"
    changed.sample(true)
    C.normal = true
    changed.userTogglePlayPause() // New player now shows an optimistic pause while truth is still playing.
    C.normal = false
    C.finish(qq)
    precondition(!changed.isPlayingSmoothed, "old player completion must preserve the new player's differing icon")

    C.normal = true
    let normal = Coordinator()
    normal.sample(true)
    normal.userTogglePlayPause()
    precondition(!normal.isPlayingSmoothed, "normal route keeps immediate optimistic pause")
    normal.userTogglePlayPause()
    precondition(normal.isPlayingSmoothed, "normal route keeps rapid double-toggle")
    precondition(C.pending.isEmpty)
    print("playback completion: 10 source-derived checks ALL PASS")
}
MainActor.assumeIsolated { replay() }
'''
with tempfile.TemporaryDirectory(prefix="lyrimuse-playback-completion-") as folder:
    path = Path(folder) / "replay.swift"
    path.write_text(program)
    subprocess.run(["swift", "-swift-version", "5", str(path)], check=True, cwd=ROOT)

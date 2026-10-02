#!/usr/bin/env swift
// Read-only acceptance check. Open PiP first, then pass the app's PID.
// --aerospace also verifies that the panel is excluded from window management.
import Foundation
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
func argument(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let rawPID = argument("--pid"), let pid = Int(rawPID) else {
    print("Usage: check-lyrics-pip.swift --pid PID [--title TITLE] [--source-title TITLE] [--aerospace PATH] [--above-window ID]")
    exit(2)
}
let title = argument("--title") ?? "Lyrics Picture in Picture"
let allWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let windows = allWindows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
guard let panel = windows.first(where: { ($0[kCGWindowName as String] as? String) == title }) else {
    print("FAIL: no independent PiP window titled '\(title)' for PID \(pid)")
    exit(1)
}
guard (panel[kCGWindowIsOnscreen as String] as? Bool) == true,
      (panel[kCGWindowLayer as String] as? Int ?? 0) > 0,
      (panel[kCGWindowAlpha as String] as? Double ?? 0) > 0,
      let id = panel[kCGWindowNumber as String] as? Int else {
    print("FAIL: PiP must be visible and above normal windows")
    exit(1)
}
if let sourceTitle = argument("--source-title") {
    guard !windows.contains(where: { ($0[kCGWindowName as String] as? String) == sourceTitle }) else {
        print("FAIL: original lyrics window '\(sourceTitle)' remains visible alongside PiP")
        exit(1)
    }
    print("PASS: original lyrics window '\(sourceTitle)' is no longer on screen")
}
if let aerospace = argument("--aerospace") {
    let task = Process(), output = Pipe()
    task.executableURL = URL(fileURLWithPath: aerospace)
    task.arguments = ["list-windows", "--all", "--json"]
    task.standardOutput = output
    do { try task.run() } catch { print("FAIL: \(error)"); exit(2) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let managed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        print("FAIL: could not read AeroSpace window list"); exit(2)
    }
    guard !managed.contains(where: { ($0["window-id"] as? Int) == id }) else {
        print("FAIL: PiP window \(id) is still managed by AeroSpace"); exit(1)
    }
    print("PASS: PiP \(id) is excluded from AeroSpace management")
}
if let otherID = argument("--above-window").flatMap(Int.init) {
    guard let otherIndex = allWindows.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == otherID }) else {
        print("ERROR: comparison window \(otherID) is not on the current screen"); exit(2)
    }
    guard let panelIndex = allWindows.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == id }),
          panelIndex < otherIndex,
          let panelBounds = panel[kCGWindowBounds as String] as? [String: Any],
          let otherBounds = allWindows[otherIndex][kCGWindowBounds as String] as? [String: Any],
          let panelRect = CGRect(dictionaryRepresentation: panelBounds as CFDictionary),
          let otherRect = CGRect(dictionaryRepresentation: otherBounds as CFDictionary),
          panelRect.intersects(otherRect) else {
        print("FAIL: PiP must be on screen, overlapping and above window \(otherID)"); exit(1)
    }
    print("PASS: PiP \(id) overlaps and is above window \(otherID)")
}
print("PASS: independent PiP \(id) is visible above normal windows")

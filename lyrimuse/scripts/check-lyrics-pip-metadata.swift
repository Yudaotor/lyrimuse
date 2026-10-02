#!/usr/bin/env swift
// Read-only UI acceptance check. Open PiP and pass the expected displayed metadata.
// Requires Accessibility permission for the invoking terminal / automation host.
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
func argument(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let rawPID = argument("--pid"), let pid = Int32(rawPID),
      let artist = argument("--artist"), let album = argument("--album") else {
    print("Usage: check-lyrics-pip-metadata.swift --pid PID --artist TEXT --album TEXT [--ad-break]")
    exit(2)
}
func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
    return result
}
func find(_ id: String, in node: AXUIElement) -> AXUIElement? {
    if value(node, kAXIdentifierAttribute) as? String == id { return node }
    for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let result = find(id, in: child) { return result }
    }
    return nil
}
func frame(_ node: AXUIElement) -> CGRect? {
    guard let point = value(node, kAXPositionAttribute), CFGetTypeID(point) == AXValueGetTypeID(),
          let size = value(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(point as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: origin, size: dimensions)
}
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL"): \(message)")
    if !condition { failures += 1 }
}
let app = AXUIElementCreateApplication(pid)
guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
    print("ERROR: cannot read windows; check the PID and Accessibility permission")
    exit(2)
}
guard let panel = windows.first(where: { value($0, kAXIdentifierAttribute) as? String == "lyrics-picture-in-picture" }),
      let panelFrame = frame(panel),
      let close = find("lyrics-pip-close", in: panel), let closeFrame = frame(close),
      let restore = find("lyrics-pip-return", in: panel), let restoreFrame = frame(restore) else {
    print("ERROR: open PiP with its Close and Return controls before running this check")
    exit(2)
}
let expected = args.contains("--ad-break") ? "" : [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
let metadata = find("lyrics-pip-metadata", in: panel)
if expected.isEmpty {
    expect(metadata == nil, "missing metadata / advertisement leaves no row or separator")
} else if let metadata {
    let text = value(metadata, kAXValueAttribute) as? String ?? value(metadata, kAXDescriptionAttribute) as? String
    expect(text == expected, "current artist and album remain fully accessible")
    expect((value(metadata, kAXHelpAttribute) as? String)?.contains(expected) == true, "hover help retains the complete names")
    if let rect = frame(metadata) {
        expect(rect.width > 0 && rect.height > 0 && panelFrame.contains(rect)
            && rect.minX >= closeFrame.maxX && rect.maxX <= restoreFrame.minX,
            "metadata fits between the window buttons at \(Int(panelFrame.width)) × \(Int(panelFrame.height))")
    } else { expect(false, "metadata has visible bounds") }
} else { expect(false, "PiP displays artist and album") }
exit(failures == 0 ? 0 : 1)

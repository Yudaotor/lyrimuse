import Foundation

/// 拖动类控件写设置的频率(14 章决策 185):写一次设置会让订阅它的展示面和设置页跟着重算,拖动中逐个事件写就卡。
/// 这里守三件事:App 场景树只订阅界面语言;每根滑杆都处理按下 / 松手(节流或草稿);颜色选择器拖动中节流写。
func runSettingsWritePressureContracts() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lyrimuse")
    func source(_ rel: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    let app = source("App.swift")
    expectEqual(app.isEmpty, false, "写设置压力(契约): 读到 App.swift")
    expectEqual(sourceHas(app, "@ObservedObject private var languageSettings: AppLanguageObserver")
                && !sourceBytes(app, contain: "ObservedObject(wrappedValue: AppSettings.shared)"),
                true, "写设置压力(契约): App 场景树只订阅界面语言,不整体观察 AppSettings(否则任何一项设置都让所有窗口场景重算)")

    // 每根滑杆的调用里都要有 onEditingChanged:拖动中要么节流写(SliderCommitThrottle)、要么只写草稿松手再写。
    // 播放器音量那根例外:它写的是播放器,自己有单飞合流。
    let exempt: Set<String> = ["MenuBar/MenuBarPanelVolume.swift"]
    var missing: [String] = []
    var scanned = 0
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for url in files {
        let rel = String(url.path.dropFirst(root.path.count + 1))
        guard !exempt.contains(rel), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for marker in ["SteppedSlider(value:", " Slider(value:"] {
            var search = text.startIndex
            while let hit = text.range(of: marker, range: search..<text.endIndex) {
                search = hit.upperBound
                guard let open = text.range(of: "(", range: hit.lowerBound..<hit.upperBound) else { continue }
                var depth = 0
                var end = open.lowerBound
                for i in text[open.lowerBound...].indices {
                    if text[i] == "(" { depth += 1 }
                    if text[i] == ")" { depth -= 1; if depth == 0 { end = i; break } }
                }
                scanned += 1
                if !text[open.lowerBound...end].contains("onEditingChanged") {
                    let line = text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1
                    missing.append("\(rel):\(line)")
                }
            }
        }
    }
    expectEqual(scanned >= 20, true, "写设置压力(契约): 扫到了全部滑杆(\(scanned) 根)")
    expectEqual(missing, [], "写设置压力(契约): 每根滑杆都处理按下 / 松手,拖动中节流或只写草稿")

    let picker = source("UI/AppColorPicker.swift")
    expectEqual(sourceCount(picker, "commitWhileDragging()\n                }\n                .onEnded { _ in commit() }"), 2,
                "写设置压力(契约): 颜色选择器拖色盘、色相条时节流写,松手补写")
    expectEqual(sourceHas(picker, "if draggingOpacity { commitWhileDragging() } else { commit() }")
                && sourceHas(picker, "guard now - lastDragCommit >= SliderCommitThrottle.interval else {"),
                true, "写设置压力(契约): 不透明度拖动中节流写,键盘增减直接写")
}

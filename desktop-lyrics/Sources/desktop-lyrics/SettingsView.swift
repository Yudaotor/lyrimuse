import SwiftUI
import AppKit
import DesktopLyricsCore

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var poller = RelayPoller.shared
    @ObservedObject private var local = LocalPlaybackSource.shared

    // 只算一次,不放进 body 里——字体族枚举+排序有大几百项,body 还会因为 poller/local
    // 这两个跟外观无关的 @ObservedObject 发布而频繁重新求值。
    private static let availableFontFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section("数据源") {
                Picker("来源", selection: Binding(
                    get: { settings.dataSourceMode },
                    set: { newValue in
                        settings.dataSourceMode = newValue
                        PlaybackCoordinator.shared.applyMode(newValue)
                    }
                )) {
                    Text("远程(网页同源)").tag(PlaybackSourceMode.relay)
                    Text("本地播放(这台 Mac)").tag(PlaybackSourceMode.local)
                }
                .pickerStyle(.segmented)

                if settings.dataSourceMode == .relay {
                    TextField("Relay 地址", text: Binding(
                        get: { settings.relayBaseURL },
                        set: { newValue in
                            settings.relayBaseURL = newValue
                            poller.updateBaseURL(newValue)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            Section("歌词展示") {
                Toggle("优先逐字高亮(有的话)", isOn: Binding(
                    get: { settings.preferWordLevelKaraoke },
                    set: { newValue in
                        settings.preferWordLevelKaraoke = newValue
                        poller.preferWordLevelKaraoke = newValue
                        local.preferWordLevelKaraoke = newValue
                    }
                ))
                Toggle("显示罗马音", isOn: $settings.showRomanization)
                Toggle("显示译文", isOn: $settings.showTranslation)
                Toggle("双行显示(预览下一句歌词)", isOn: $settings.showNextLinePreview)
            }
            Section("外观") {
                Picker("字体", selection: $settings.fontFamilyName) {
                    Text("跟随系统").tag("")
                    ForEach(Self.availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu) // 字体族列表常有一两百项,显式用菜单样式,不依赖 Form 自动推断

                HStack {
                    Text("字号")
                    Slider(value: $settings.fontSize, in: 14...36, step: 1)
                    Text("\(Int(settings.fontSize))pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }

                ColorPicker(
                    "文字颜色",
                    selection: Binding(
                        get: { settings.foregroundColor },
                        set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                    ),
                    supportsOpacity: false // 故意关掉——文字颜色允许透明的话,容易把 alpha
                                           // 拖到 0,悬浮窗整个消失且没有任何视觉提示能定位问题
                )

                ColorPicker(
                    "背景颜色",
                    selection: Binding(
                        get: { settings.backgroundColor },
                        set: { settings.backgroundColorHex = $0.hexStringWithAlpha }
                    ),
                    supportsOpacity: true // 背景不透明度就是这个颜色的 alpha 通道本身,
                                          // 不另加一根 opacity 滑杆
                )

                Button("恢复默认外观") {
                    settings.fontFamilyName = ""
                    settings.fontSize = 20
                    settings.foregroundColorHex = "#FFFFFFFF"
                    settings.backgroundColorHex = "#00000000"
                }
                .buttonStyle(.link)
            }
            Section("窗口") {
                Toggle("锁定位置(不可拖拽+点击穿透)", isOn: Binding(
                    get: { settings.lockPosition },
                    set: { newValue in
                        settings.lockPosition = newValue
                        LyricsOverlayWindowController.shared.setLocked(newValue)
                    }
                ))
            }
            Section("启动") {
                Toggle("开机启动", isOn: $settings.launchAtLoginEnabled)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

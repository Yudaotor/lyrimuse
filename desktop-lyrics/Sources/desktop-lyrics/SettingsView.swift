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
        // .formStyle(.grouped) 是 macOS 13+ 原生"系统设置"式外观(圆角分组卡片+
        // 灰色小标题+尾注),换掉原来 Form 默认的纯列表样式——原来的问题:每个 Section
        // 的标题只是一行普通粗体文字、跟内容之间没有视觉分组;ColorPicker/字体 Picker
        // 在默认样式下会被拉伸成贯穿整行的长条,不像系统里那种紧凑的小色块/下拉按钮;
        // 说明性文字(截屏隐藏/歌词存储那两句)夹在控件中间当成普通一行,读起来像是漏了
        // 什么而不是备注。分组样式换来的排版全部是 SwiftUI 原生处理,不用手工调间距。
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

                // LabeledContent 而不是裸 HStack——分组样式下 Toggle/Picker/ColorPicker
                // 这些自带标签的控件,标签会自动对齐成同一条竖线;裸 HStack 的"字号"只是
                // 行内第一个 Text,对不上那条对齐线。LabeledContent 让它享受同一套对齐。
                LabeledContent("字号") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.fontSize, in: 14...36, step: 1)
                        Text("\(Int(settings.fontSize))pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
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

                Toggle("文字阴影(与桌面背景区分)", isOn: $settings.textShadowEnabled)

                if settings.textShadowEnabled {
                    ColorPicker(
                        "阴影颜色",
                        selection: Binding(
                            get: { settings.textShadowColor },
                            set: { settings.textShadowColorHex = $0.hexStringWithAlpha }
                        ),
                        supportsOpacity: true // 参考 LyricsX:阴影只让选颜色(含 alpha),
                                              // 模糊半径/偏移是固定常量,不额外加调节项
                    )
                }

                Button("恢复默认外观") {
                    settings.fontFamilyName = ""
                    settings.fontSize = 20
                    settings.foregroundColorHex = "#FFFFFFFF"
                    settings.backgroundColorHex = "#00000000"
                    settings.textShadowEnabled = true
                    settings.textShadowColorHex = "#000000A6"
                }
                .buttonStyle(.link)
            }

            Section {
                Toggle("锁定位置(不可拖拽+点击穿透)", isOn: Binding(
                    get: { settings.lockPosition },
                    set: { newValue in
                        settings.lockPosition = newValue
                        LyricsOverlayWindowController.shared.setLocked(newValue)
                    }
                ))
                Toggle("截屏/录屏时隐藏", isOn: Binding(
                    get: { settings.hideDuringScreenCapture },
                    set: { newValue in
                        settings.hideDuringScreenCapture = newValue
                        LyricsOverlayWindowController.shared.setHiddenFromCapture(newValue)
                    }
                ))
            } header: {
                Text("窗口")
            } footer: {
                // footer 挂在整个 Section 上(而不是紧跟某个 Toggle 下面的裸 Text)——
                // 分组样式里这是原生"注脚"位置,明确点名是哪个开关的说明,避免视觉上跟
                // "锁定位置"混在一起。
                Text("开启「截屏/录屏时隐藏」后,截图、录屏、视频会议共享屏幕都不会拍到悬浮歌词——但你自己在这台 Mac 上仍然正常看得见。")
            }

            Section("启动") {
                Toggle("开机启动", isOn: $settings.launchAtLoginEnabled)
            }

            Section {
                Button("打开歌词文件夹") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".config/applemusic-nowplaying/lyrics")
                    // collector 那边(见 collector/lyricsexport.go)只在真正解析/导出过至少
                    // 一首歌之后才会建这个目录,这里先兜底建一下,避免文件夹还不存在时
                    // NSWorkspace 打不开、又没有任何提示。
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            } header: {
                Text("存储")
            } footer: {
                Text("每首歌听过一次,歌词就会永久保存在本地——即使之后在「歌词管理」里删除也不影响这里已导出的文件。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

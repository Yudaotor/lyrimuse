import SwiftUI
import DesktopLyricsCore

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var poller = RelayPoller.shared
    @ObservedObject private var local = LocalPlaybackSource.shared

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
            Section("启动") {
                Toggle("开机启动", isOn: $settings.launchAtLoginEnabled)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

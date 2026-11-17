import AppKit
import LyrimuseCore
import SwiftUI

/// 「本次更新」卡片(`Window(id: "whats-new")`,见 App.swift):菜单栏面板顶部的「已更新到 X」、右键菜单「查看本次更新…」
/// 和深链 `whats-new` 开它。内容是包里 CHANGELOG 的当前版本那一节(`WhatsNewCenter.currentNotes`),分小节列条目;
/// 底下一个去 GitHub 发布页的链接和「好」。见 14 章决策 155。
struct WhatsNewWindow: View {
    static let sceneID = "whats-new"

    @State private var sections: [ReleaseNotes.Section] = []
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    @Environment(\.dismissWindow) private var dismissWindow

    private let version = SparkleUpdaterManager.appVersionString

    var body: some View {
        VStack(spacing: 0) {
            header
            if sections.isEmpty {
                ContentUnavailableView(String(format: L10n.t("%@ 更新内容"), version), systemImage: "sparkles")
                    .frame(maxHeight: .infinity)
            } else {
                notes
            }
            footer
        }
        .frame(width: 520, height: 600)
        .background { LastfmGlassGlow().ignoresSafeArea() }
        .navigationTitle(String(format: L10n.t("%@ 更新内容"), version))
        .task(id: L10n.current) { sections = WhatsNewCenter.currentNotes() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            LyrimuseAppIconImage()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text(String(format: L10n.t("%@ 更新内容"), version))
                .font(.system(size: 18, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 8) {
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "•")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Text(item)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCardBackground(cornerRadius: 14)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.t("在 GitHub 查看这一版的发布说明")) {
                NSWorkspace.shared.open(UpdateChannel.releasePageURL(displayVersion: version))
            }
            .buttonStyle(.link)
            Spacer(minLength: 12)
            Button(L10n.t("好")) { dismissWindow(id: Self.sceneID) }
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 12.5))
        .settingsGlassButtons()
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

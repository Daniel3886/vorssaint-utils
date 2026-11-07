// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Chooses where files dropped on the island's send zone go: AirDrop, any
/// service in the Share menu, the menu itself, or an app picked from disk.
struct NotchSendSettingsRow: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchSendTarget) private var stored = NotchSendTarget.defaultValue.stored
    @State private var options: [NotchSendService.Option] = []
    @State private var choosingApp = false

    /// Picking this tag asks for an app instead of storing a value.
    private static let otherApp = NotchSendTarget.app("")

    private var text: NotchFilesStrings { FeatureStrings.notchFiles(l10n.language) }
    private var current: NotchSendTarget { NotchSendTarget(stored: stored) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsMenuRow(symbol: "paperplane", title: text.sendTarget,
                            selection: Binding(get: { current }, set: choose)) {
                Text(text.sendOff).tag(NotchSendTarget.off)
                ForEach(options) { option in Text(option.title).tag(option.target) }
                // A service that is not offered right now, or an app chosen
                // earlier, keeps its own entry so the menu shows it.
                if current != .off, current != .shareMenu, !options.contains(where: { $0.target == current }) {
                    Text(NotchSendService.shared.display(for: current).title).tag(current)
                }
                Text(text.sendShareMenu).tag(NotchSendTarget.shareMenu)
                Text(text.sendOtherApp).tag(Self.otherApp)
            }
            .disabled(choosingApp)
            Text(text.sendHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, settingsRowTextInset)
        }
        .onAppear { options = NotchSendService.shared.options() }
    }

    private func choose(_ target: NotchSendTarget) {
        guard target == Self.otherApp else {
            stored = target.stored
            return
        }
        choosingApp = true
        NotchSendService.shared.chooseApp { chosen in
            choosingApp = false
            if let chosen { stored = chosen.stored }
        }
    }
}

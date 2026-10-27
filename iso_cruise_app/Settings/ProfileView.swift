import CoreBluetooth
import SwiftUI
import UserNotifications

/// Nickname editing plus a plain-language summary of privacy and limitations.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(SessionManager.self) private var session
    @Environment(ConnectionSettings.self) private var connectionSettings
    @Environment(OnlineStatus.self) private var online
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notificationsAllowed: Bool?
    @State private var showConnectGuide = false
    @Environment(\.openURL) private var openURL

    private var nicknameProblem: String? {
        guard let clean = Nickname.sanitize(name) else { return nil }
        if case .blocked(let reason) = ContentFilter.shared.checkNickname(clean) { return reason.message }
        return nil
    }

    private var canSave: Bool {
        guard let clean = Nickname.sanitize(name), nicknameProblem == nil else { return false }
        return clean != profile.nickname
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    LabeledContent("Your tag", value: "#\(session.localIdentity.tag)")
                } header: {
                    Text("Nickname")
                } footer: {
                    if let nicknameProblem {
                        Text(nicknameProblem).foregroundStyle(.red)
                    } else {
                        Text("Nicknames aren't verified, but your tag can't be faked: friends can check it to know it's really you. Changing your nickname reconnects you.")
                    }
                }

                Section {
                    @Bindable var connectionSettings = connectionSettings
                    Toggle(isOn: $connectionSettings.nearbyRadioEnabled) {
                        Label("Nearby radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Label("Wi-Fi network", systemImage: "wifi")
                        .badge(Text("Always on"))
                } header: {
                    Text("Connections")
                } footer: {
                    Text(connectionSettings.nearbyRadioEnabled
                         ? "CruiseLAN uses both. Nearby radio connects phones a few steps apart with no shared network. The Wi-Fi network reaches across a building, but only between phones joined to the same Wi-Fi, and some hotel and ship networks block it. Turn Nearby radio off to test the Wi-Fi network on its own."
                         : "Only the Wi-Fi network is used: you'll only see people joined to the same Wi-Fi as you. If nobody shows up, this network may block phones from seeing each other; turn Nearby radio back on. Bluetooth still reaches locked phones nearby.")
                }

                Section {
                    @Bindable var connectionSettings = connectionSettings
                    Toggle(isOn: $connectionSettings.onlineGamesEnabled) {
                        Label("Online games", systemImage: "globe")
                    }
                    if connectionSettings.onlineGamesEnabled {
                        LabeledContent("Right now", value: onlineStatusText)
                    }
                } header: {
                    Text("Games")
                } footer: {
                    Text(connectionSettings.onlineGamesEnabled
                         ? "With internet, games are hosted online: share a code and play with anyone, anywhere, even on hotel or ship Wi-Fi that hides phones from each other. Without internet, a phone hosts the game and players need to be connected nearby."
                         : "Every game is hosted on a phone, and players need to be connected nearby. Turn this on to play online when the internet is available.")
                }

                Section {
                    LabeledContent("Bluetooth", value: bluetoothStatus)
                    LabeledContent("Notifications", value: notificationsAllowed.map { $0 ? "Allowed" : "Off" } ?? "…")
                    if !isReadyForAwayMessages, let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open CruiseLAN Settings") { openURL(url) }
                    }
                } header: {
                    Text("When your phone is locked")
                } footer: {
                    Text("Friends nearby reach your phone over Bluetooth while CruiseLAN is in the background, so you get their messages and turns. This needs Bluetooth and Notifications on for CruiseLAN. Don't swipe CruiseLAN away in the app switcher: iOS can't wake an app that was closed that way, so nothing arrives until you open it again.")
                }

                Section("Safety") {
                    TipRow(symbol: "hand.raised.fill", text: "A safety filter blocks bad words, sexual content, and personal info like phone numbers, emails, links, social media, and cabin numbers.")
                    TipRow(symbol: "exclamationmark.bubble.fill", text: "Touch and hold a message to report or block someone. Tell a parent or crew member if anything feels wrong.")
                    NavigationLink("Blocked People (\(session.safety.blocked.count))") {
                        BlockedPeopleView()
                    }
                }

                Section("Privacy") {
                    TipRow(symbol: "lock.fill", text: "Messages are end-to-end encrypted: phones that pass them along can't read them.")
                    // Diagnostics sharing is off unless the user turns it on, so this stays
                    // accurate either way rather than claiming "no analytics" outright.
                    TipRow(symbol: "icloud.slash", text: "No accounts, servers, or internet. Anonymous diagnostics are only sent if you turn them on.")
                    TipRow(symbol: "trash", text: "Chats and games live only in memory and disappear when you quit.")
                }

                Section {
                    Button("How to connect") { showConnectGuide = true }
                    NavigationLink("Troubleshooting") { TroubleshootingView() }
                    NavigationLink("Insights") { InsightsView() }
                    Button("Show first-run tips again") { profile.resetGuidance() }
                } header: {
                    Text("Help & diagnostics")
                } footer: {
                    Text("Troubleshooting explains what's working and what isn't. Insights shows what CruiseLAN has measured about itself on this phone.")
                }

                Section("Good to know") {
                    TipRow(symbol: "antenna.radiowaves.left.and.right", text: "Phones running CruiseLAN pass messages along for each other, so the more people nearby have it open, the further it reaches. Some Wi-Fi networks block it.")
                    TipRow(symbol: "moon.zzz", text: "When you switch apps, games pause for up to 10 minutes. Friends nearby can nudge your phone over Bluetooth when it's your turn or they send a message.")
                }

                if SafetyConfig.reportEmail != nil || SafetyConfig.supportURL != nil || SafetyConfig.privacyPolicyURL != nil {
                    Section("Help") {
                        if let email = SafetyConfig.reportEmail, let url = URL(string: "mailto:\(email)") {
                            Link(destination: url) {
                                LabeledContent("Contact Us", value: email)
                            }
                        }
                        if let supportURL = SafetyConfig.supportURL {
                            Link("Support", destination: supportURL)
                        }
                        if let privacyPolicyURL = SafetyConfig.privacyPolicyURL {
                            Link("Privacy Policy", destination: privacyPolicyURL)
                        }
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if profile.setNickname(name) {
                            session.nicknameDidChange()
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showConnectGuide) { GetConnectedView() }
            .onAppear { name = profile.nickname ?? "" }
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationsAllowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            }
        }
    }
}

extension ProfileView {
    private var onlineStatusText: String {
        switch online.state {
        case .checking: "Checking…"
        case .online: "Online"
        case .offline: "No internet: games are hosted nearby"
        }
    }

    private var bluetoothStatus: String {
        switch CBManager.authorization {
        case .allowedAlways: "Allowed"
        case .denied, .restricted: "Off"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    private var isReadyForAwayMessages: Bool {
        CBManager.authorization == .allowedAlways && notificationsAllowed != false
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Attribution required by the licenses of the safety-filter word lists.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("The safety filter's word list contains material from the following projects, modified for CruiseLAN.")
            }
            Section("List of Dirty, Naughty, Obscene, and Otherwise Bad Words") {
                Text("© Shutterstock, Inc. Licensed under Creative Commons Attribution 4.0 International (CC BY 4.0). Modified: entries removed and added for a kid-safe chat app.")
                Link("creativecommons.org/licenses/by/4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }
            Section("obscenity") {
                Text("© 2025 Joseph Liu. MIT License.")
            }
            Section("cuss") {
                Text("© 2016 Titus Wormer. MIT License.")
            }
            Section("MIT License") {
                Text("Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

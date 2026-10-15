import SwiftUI

/// Nickname editing plus a plain-language summary of privacy and limitations.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

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
                        Text("Nicknames aren't verified, so the tag helps people tell you apart. Changing your nickname reconnects you.")
                    }
                }

                Section("Safety") {
                    TipRow(symbol: "hand.raised.fill", text: "A safety filter blocks bad words, sexual content, and personal info like phone numbers, emails, links, social media, and cabin numbers.")
                    TipRow(symbol: "exclamationmark.bubble.fill", text: "Touch and hold a message to report or block someone. Tell a parent or crew member if anything feels wrong.")
                    NavigationLink("Blocked People (\(session.safety.blocked.count))") {
                        BlockedPeopleView()
                    }
                }

                Section("Privacy") {
                    TipRow(symbol: "lock.fill", text: "Connections between phones are encrypted.")
                    TipRow(symbol: "icloud.slash", text: "No accounts, servers, analytics, or internet.")
                    TipRow(symbol: "trash", text: "Chats and games live only in memory and disappear when you quit.")
                }

                Section("Good to know") {
                    TipRow(symbol: "antenna.radiowaves.left.and.right", text: "CruiseLAN reaches people nearby. It is not a ship-wide network, and some Wi-Fi networks block it.")
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
            .onAppear { name = profile.nickname ?? "" }
        }
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

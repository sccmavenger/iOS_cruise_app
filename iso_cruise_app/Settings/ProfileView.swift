import SwiftUI

/// Nickname editing plus a plain-language summary of privacy and limitations.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var canSave: Bool {
        guard let clean = Nickname.sanitize(name) else { return false }
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
                    Text("Nicknames aren't verified, so the tag helps people tell you apart. Changing your nickname reconnects you.")
                }

                Section("Privacy") {
                    TipRow(symbol: "lock.fill", text: "Connections between phones are encrypted.")
                    TipRow(symbol: "icloud.slash", text: "No accounts, servers, analytics, or internet.")
                    TipRow(symbol: "trash", text: "Chats and games live only in memory and disappear when you quit.")
                }

                Section("Good to know") {
                    TipRow(symbol: "antenna.radiowaves.left.and.right", text: "CruiseLAN reaches people nearby. It is not a ship-wide network, and some Wi-Fi networks block it.")
                    TipRow(symbol: "moon.zzz", text: "Connections pause when CruiseLAN goes to the background.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
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

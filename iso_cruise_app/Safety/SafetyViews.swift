import SwiftUI

/// Who or what is being reported.
struct ReportTarget: Identifiable, Equatable {
    let identityId: String
    let name: String
    let message: String?
    /// Set for a player in an online game: their seat has no identity beyond that game, so the
    /// report names the game instead, and there's nothing on this phone to block.
    var onlineCode: String? = nil

    var id: String { identityId + (message ?? "") }
}

/// Report flow: always blocks the person on this device, and (when a safety contact is
/// configured) opens a pre-filled email. Nothing is sent without the user tapping Send in Mail.
struct ReportView: View {
    let target: ReportTarget
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var reason = Reason.inappropriate
    @State private var didReport = false
    /// Mail isn't set up on this phone, so show the address to write to instead.
    @State private var mailUnavailable = false

    enum Reason: String, CaseIterable, Identifiable {
        case inappropriate = "Bad words or inappropriate content"
        case bullying = "Being mean or bullying"
        case personalInfo = "Asking for personal information"
        case uncomfortable = "Made me feel uncomfortable"
        case other = "Something else"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                if didReport {
                    Section {
                        if target.onlineCode == nil {
                            Label("\(target.name) is blocked", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text("You won't see their games, messages or invitations anymore.")
                        } else {
                            Label("Thanks for telling us", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text("You can leave this game at any time. A host can also remove a player from the lobby.")
                        }
                        Text("If someone made you feel unsafe or uncomfortable, tell a parent or a crew member right away.")
                            .fontWeight(.semibold)
                    }
                    if mailUnavailable, let email = SafetyConfig.reportEmail {
                        Section("Send the report") {
                            Text("Mail isn't set up on this phone. A parent can email the report to:")
                            Text(email)
                                .textSelection(.enabled)
                                .fontWeight(.semibold)
                        }
                    }
                } else {
                    Section {
                        Picker("What happened?", selection: $reason) {
                            ForEach(Reason.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Report \(target.name)")
                    } footer: {
                        Text(target.onlineCode == nil ? "Reporting also blocks this person on your phone." : "The report names this online game so we can look into it.")
                    }

                    if let message = target.message {
                        Section("Message") {
                            Text(message).foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            submit()
                        } label: {
                            Text(target.onlineCode == nil ? "Block and Report" : "Report")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didReport ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        let body = session.reportBody(about: target.identityId, message: target.message, reason: reason.rawValue,
                                      name: target.name, onlineGame: target.onlineCode.map(CloudConfig.displayCode))
        if target.onlineCode == nil { session.block(identityId: target.identityId) }
        didReport = true
        if let email = SafetyConfig.reportEmail, let url = Self.mailURL(to: email, body: body) {
            openURL(url) { accepted in
                mailUnavailable = !accepted
            }
        }
    }

    static func mailURL(to email: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "CruiseLAN safety report"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}

/// Lists people blocked on this device so they can be unblocked.
struct BlockedPeopleView: View {
    @Environment(SessionManager.self) private var session

    var body: some View {
        List {
            if session.safety.blocked.isEmpty {
                Text("You haven't blocked anyone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.safety.blocked) { person in
                HStack {
                    VStack(alignment: .leading) {
                        Text(person.name)
                        Text("Blocked \(person.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unblock") { session.unblock(person) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Blocked People")
    }
}

import SwiftUI

/// Shown once, straight after onboarding: gets the user to their **first connection**.
///
/// **Why this screen exists.** CruiseLAN's hard part isn't navigation — there are two tabs.
/// It's the cold start: a new user opens the app alone, sees an empty People list, and has
/// no way to tell "nobody is here yet" from "this is broken". Every other messaging app
/// arrives already knowing your contacts; this one arrives empty and stays empty until a
/// second person does something.
///
/// So rather than explain the tabs, this screen walks the one ritual that unblocks
/// everything, and shows the live peer list *inline* — so the user watches a friend appear
/// while being told what's happening, instead of reading a description of it.
///
/// See docs/decisions/onboarding-tour.md.
struct GetConnectedView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(SessionManager.self) private var session
    @Environment(NetworkPathProbe.self) private var probe
    @Environment(\.lanTransport) private var lan
    @Environment(\.dismiss) private var dismiss

    @State private var situation: Situation = .together
    @State private var showScanner = false

    /// Where the user's group actually is, which changes what advice is useful.
    private enum Situation: String, CaseIterable, Identifiable {
        case together = "We're together"
        case apart = "We're far apart"
        case alone = "I'm on my own"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    hotspotNote
                    picker

                    switch situation {
                    case .together: togetherSection
                    case .apart: apartSection
                    case .alone: aloneSection
                    }
                }
                .padding(24)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Get Connected")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom) {
                Button {
                    profile.markSeen(.connectGuide)
                    dismiss()
                } label: {
                    Text(session.connectedIdentities.isEmpty ? "I'll do this later" : "Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .sheet(isPresented: $showScanner) {
                if let lan { JoinByCodeView(lan: lan) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CruiseLAN needs someone to talk to")
                .font(.title2.bold())
            Text("It doesn't use the internet, so there's nobody online waiting. You connect to real people who are on the ship with you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// A hotspot is a private network with no isolation, so it always works. Saying so turns
    /// the most common dead end into a known-good answer.
    @ViewBuilder
    private var hotspotNote: some View {
        let role = LANAddress.hotspotRole()
        if role != .none {
            Label(
                role == .sharing
                    ? "You're sharing a Personal Hotspot. Anyone who joins it can always reach you."
                    : "You're on a Personal Hotspot. Everyone on it can always reach each other.",
                systemImage: "personalhotspot"
            )
            .font(.footnote)
            .foregroundStyle(Theme.teal)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var picker: some View {
        Picker("Where is everyone?", selection: $situation) {
            ForEach(Situation.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Together

    private var togetherSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepRow(number: 1, text: "Have everyone open CruiseLAN and pick a nickname.")
            StepRow(number: 2, text: "Wait a few seconds. You'll see each other appear below.")
            StepRow(number: 3, text: "Tap a name to send a connection request. Once they accept, you can chat and play.")

            livePeerList
        }
    }

    /// The payoff, on the same screen as the instructions.
    @ViewBuilder
    private var livePeerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People near you")
                .font(.headline)

            let people = session.discoveredPeople
            let contacts = session.connectedIdentities

            if !contacts.isEmpty {
                ForEach(contacts, id: \.id) { contact in
                    Label(contact.labeledName, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.teal)
                }
                Text("Connected. You're all set — open Chat or Games.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !people.isEmpty {
                ForEach(people) { person in
                    Label(person.labeledName, systemImage: "person.circle")
                        .font(.subheadline)
                }
                Text("Found them. Open the People list from Chat to send a request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(waitingHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// If a radio or permission is actually missing, say that instead of "looking…" forever.
    private var waitingHint: String {
        let conditions = probe.conditions
        if conditions.isLocalNetworkDenied {
            return "CruiseLAN can't see this network. Allow Local Network access in Settings."
        }
        if !conditions.hasWiFi && !conditions.bluetooth.isUsable {
            return "Turn on Wi-Fi or Bluetooth so CruiseLAN can look for people."
        }
        return "Everyone needs the app open. If you're not in the same room, try \"We're far apart\"."
    }

    // MARK: - Apart

    private var apartSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Some hotel and ship networks stop phones from finding each other, even though they're both online. Scanning a code skips the searching.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            StepRow(number: 1, text: "Make sure you're both on the same Wi-Fi network.")
            StepRow(number: 2, text: "One of you shows their code; the other scans it.")

            if lan != nil {
                Button {
                    showScanner = true
                } label: {
                    Label("Show or scan a code", systemImage: "qrcode")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
            }

            Text("Still nothing? That network is probably blocking phones from reaching each other. One of you can share a Personal Hotspot and have everyone join it — that always works.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Alone

    private var aloneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CruiseLAN only works with other people running it nearby. There's no one to match you with, because there's no server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let url = SafetyConfig.supportURL {
                ShareLink(item: url) {
                    Label("Invite someone", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
            }

            Text("Send this to whoever you're travelling with. Once they've installed it and opened it nearby, you'll see each other.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A numbered instruction. Numbered rather than bulleted because the order matters here —
/// the app genuinely does not work until step 1 has happened on a second phone.
private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.teal, in: Circle())
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }
}

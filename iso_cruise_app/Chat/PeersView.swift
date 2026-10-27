import SwiftUI
import UIKit

/// Contacts (connected and away), contact requests, and people on the mesh who can be
/// asked to connect, plus what to check when nobody shows up.
struct PeersView: View {
    @Environment(SessionManager.self) private var session
    @Environment(AppState.self) private var app
    @Environment(GameCoordinator.self) private var games
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Ticks every few seconds so "nearby" ages out and troubleshooting tips can appear after a delay.
    @State private var clock = Date.now
    @State private var reportTarget: ReportTarget?

    /// Seconds without anyone before troubleshooting tips appear.
    private static let troubleshootingDelay: TimeInterval = 20

    var body: some View {
        NavigationStack {
            List {
                if case .failed(let message) = session.status {
                    Section {
                        Label("Nearby search couldn't start: \(message)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Try Again") { session.start() }
                    }
                }

                if !session.invitations.isEmpty {
                    Section {
                        ForEach(session.invitations) { invitation in
                            RequestRow(invitation: invitation)
                        }
                    } header: {
                        Text("Requests")
                    } footer: {
                        Text("Only accept people you recognize. Names aren't verified, but the tag after a name (like #A1B2) can't be faked: check it with them. If you decline, they can't ask again for 10 minutes.")
                    }
                }

                Section("Connected") {
                    if session.connectedIdentities.isEmpty {
                        Text("No one yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.connectedIdentities, id: \.id) { identity in
                        ContactRow(identity: identity, isAway: false, hops: session.directory[identity.id]?.hops,
                                   media: session.media(for: identity.id))
                            .swipeActions {
                                Button("Block", systemImage: "hand.raised", role: .destructive) {
                                    session.block(identityId: identity.id)
                                }
                                Button("Message", systemImage: "bubble.left") { message(identity) }
                                    .tint(Theme.teal)
                            }
                            .contextMenu { contactMenu(identity) }
                    }
                    if !session.knownIdentities.isEmpty {
                        Button("Disconnect from Everyone", role: .destructive) {
                            // Leave any game properly first, so others aren't left waiting for us.
                            if games.lobby != nil { games.leave() }
                            session.disconnectAll()
                        }
                    }
                }

                let media = session.linkMedia
                if !media.isEmpty {
                    ConnectionSummarySection(media: media)
                }

                let away = session.awayIdentityIds.compactMap { session.knownIdentities[$0] }
                if !away.isEmpty {
                    Section {
                        ForEach(away, id: \.id) { identity in
                            ContactRow(identity: identity, isAway: true, hops: nil,
                                       awaySince: session.droppedAt[identity.id])
                                .swipeActions {
                                    Button("Block", systemImage: "hand.raised", role: .destructive) {
                                        session.block(identityId: identity.id)
                                    }
                                    Button("Message", systemImage: "bubble.left") { message(identity) }
                                        .tint(Theme.teal)
                                }
                                .contextMenu { contactMenu(identity) }
                        }
                    } header: {
                        Text("Away")
                    } footer: {
                        Text("They switched apps, locked their phone, or are out of reach. They reconnect automatically when they're back. Messages you send are held for them, and nearby phones get a notification over Bluetooth.")
                    }
                }

                Section {
                    let people = session.discoveredPeople
                    if people.isEmpty {
                        Text("Looking for people…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(people) { person in
                        let waiting = session.isRequested(person.id)
                        Button {
                            session.requestContact(person.id)
                        } label: {
                            MeshPersonRow(person: person, isWaiting: waiting, media: session.media(for: person.id))
                        }
                        .disabled(waiting)
                        .accessibilityHint("Sends a request to connect")
                        .contextMenu {
                            Button("Block", systemImage: "hand.raised", role: .destructive) {
                                session.block(identityId: person.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("People on CruiseLAN")
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Searching")
                    }
                } footer: {
                    Text("Phones running CruiseLAN pass messages along for each other, so you can reach people further away than your phone can. They can't read your messages: only you and the people you're talking to can. Tap someone to ask to connect; you can chat once they accept.")
                }

                if shouldShowTroubleshooting(at: clock) {
                    TroubleshootingSection {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    clock = .now
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .sheet(item: $reportTarget) { ReportView(target: $0) }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func contactMenu(_ identity: PeerIdentity) -> some View {
        Button("Message", systemImage: "bubble.left") { message(identity) }
        Button("Report…", systemImage: "exclamationmark.bubble") {
            reportTarget = ReportTarget(identityId: identity.id, name: identity.nickname, message: nil)
        }
        Button("Block", systemImage: "hand.raised", role: .destructive) {
            session.block(identityId: identity.id)
        }
    }

    /// Opens (or starts) a one-on-one chat.
    private func message(_ identity: PeerIdentity) {
        let conversation = session.directConversation(with: identity)
        dismiss()
        app.open(conversation: conversation.id)
    }

    private func shouldShowTroubleshooting(at date: Date) -> Bool {
        _ = date
        guard session.connectedIdentities.isEmpty, session.discoveredPeople.isEmpty else { return false }
        switch session.status {
        case .running(let since): return date.timeIntervalSince(since) > Self.troubleshootingDelay
        case .failed: return true
        case .idle: return false
        }
    }
}

/// How far someone is, in words.
private func distanceText(hops: Int?) -> String? {
    guard let hops else { return nil }
    switch hops {
    case 0: return "Nearby"
    case 1: return "Through 1 phone"
    default: return "Through \(hops) phones"
    }
}

struct ContactRow: View {
    let identity: PeerIdentity
    let isAway: Bool
    let hops: Int?
    /// Direct links to them right now (see `SessionManager.media(for:)`).
    var media: [LinkMedium] = []
    /// When they dropped, for away contacts. Shown so a long-departed friend doesn't look
    /// like a stuck row — contacts are kept for hours on purpose, to hold messages for them.
    var awaySince: Date?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isAway ? "moon.zzz.fill" : "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(isAway ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.teal))
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.labeledName)
                if isAway {
                    if let awaySince, let age = MeshPersonRow.ageText(since: awaySince) {
                        Text(age.replacingOccurrences(of: "seen ", with: "left "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !media.isEmpty {
                    MediaLabel(media: media)
                } else if let distance = distanceText(hops: hops) {
                    Text(distance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isAway {
                Text("Away")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MeshPersonRow: View {
    let person: SessionManager.MeshPerson
    let isWaiting: Bool
    var media: [LinkMedium] = []

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: person.hops == 0 ? "iphone.gen3.radiowaves.left.and.right" : "point.3.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundStyle(Theme.teal)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.labeledName)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(isWaiting ? "Waiting…" : "Invite")
                .font(.subheadline.weight(isWaiting ? .regular : .semibold))
                .foregroundStyle(isWaiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.teal))
        }
        .accessibilityElement(children: .combine)
    }

    /// Distance plus how long ago they were last heard from.
    ///
    /// The age is here because of tester feedback: "I closed the app on test-phone but it's
    /// still showing up several minutes after". Someone who leaves ages out of this list on
    /// their own, but with no sense of *when* they were last seen there's nothing to
    /// distinguish "here right now" from "about to disappear" — so a list that's working
    /// correctly reads as a stuck one.
    private var subtitle: String? {
        let distance = media.isEmpty ? distanceText(hops: person.hops) : media.map(\.label).joined(separator: " + ")
        let age = Self.ageText(since: person.lastHeard)
        return [distance, age].compactMap { $0 }.joined(separator: " · ")
    }

    /// Coarse on purpose: announcements arrive every 20s, so anything finer than this would
    /// imply a precision the mesh doesn't have.
    static func ageText(since lastHeard: Date) -> String? {
        let seconds = Int(Date.now.timeIntervalSince(lastHeard))
        guard seconds >= 0 else { return nil }
        switch seconds {
        case ..<25: return "seen just now"
        case ..<60: return "seen \(seconds)s ago"
        default: return "seen \(seconds / 60)m ago"
        }
    }
}

/// "Wi-Fi network + Nearby radio", with an icon per path.
struct MediaLabel: View {
    let media: [LinkMedium]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(media, id: \.self) { medium in
                Image(systemName: medium.symbol)
                    .accessibilityHidden(true)
            }
            Text(media.map(\.label).joined(separator: " + "))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Which kinds of connection are working right now, with how many phones each reaches and
/// what each one means. Answers "am I on Bluetooth, the Wi-Fi, or what?" without guessing:
/// it lists only what the transports report for live links.
struct ConnectionSummarySection: View {
    let media: [LinkMedium]

    private var counts: [(medium: LinkMedium, count: Int)] {
        Dictionary(grouping: media, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.medium.sortOrder < $1.medium.sortOrder }
    }

    var body: some View {
        Section {
            ForEach(counts, id: \.medium) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.medium.symbol)
                        .font(.title3)
                        .foregroundStyle(Theme.teal)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.medium.label)
                            Spacer()
                            Text(entry.count == 1 ? "1 phone" : "\(entry.count) phones")
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.medium.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("How you're connected")
        } footer: {
            Text("These are this phone's direct links, to anyone running CruiseLAN nearby. People shown as \"Through 1 phone\" are reached by passing messages along those links. The same person can be linked more than one way at once; if one path drops, the other keeps working.")
        }
    }
}

/// Someone asking to connect, with Accept and Decline.
struct RequestRow: View {
    @Environment(SessionManager.self) private var session
    let invitation: SessionManager.Invitation

    var body: some View {
        // Name on top, buttons underneath, so long names and large text sizes still fit.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title3)
                    .foregroundStyle(Theme.teal)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invitation.labeledName)
                    Text("Wants to connect")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 10) {
                Button { session.respond(to: invitation, accept: false) } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Decline \(invitation.displayName)")
                Button { session.respond(to: invitation, accept: true) } label: {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .accessibilityLabel("Accept \(invitation.displayName)")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Honest guidance for networks where discovery doesn't work.
struct TroubleshootingSection: View {
    let openSettings: () -> Void

    var body: some View {
        Section("Not finding anyone?") {
            TipRow(symbol: "hand.raised.fill", text: "Make sure Local Network access is on: Settings › Privacy & Security › Local Network › CruiseLAN.")
            Button("Open CruiseLAN Settings", action: openSettings)
            TipRow(symbol: "wifi", text: "Keep Wi-Fi and Bluetooth turned on (you don't need to join a network). Stay close to each other.")
            TipRow(symbol: "app.badge", text: "The other person must have CruiseLAN open in the foreground. Anyone with CruiseLAN open in between helps pass messages along.")
            TipRow(symbol: "ferry", text: "Some ship and hotel Wi-Fi networks block devices from seeing each other. If you're joined to one, try turning Wi-Fi off and on, or moving closer together.")
        }
    }
}

struct TipRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.teal)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

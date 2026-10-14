import SwiftUI
import UIKit

/// Lists connected and discovered peers, lets the user invite people, and explains
/// what to check when nobody shows up.
struct PeersView: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Ticks every few seconds so the troubleshooting tips can appear after a delay.
    @State private var clock = Date.now

    /// Seconds without any peer before troubleshooting tips appear.
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

                Section("Connected") {
                    if session.connectedPeers.isEmpty {
                        Text("No one yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.connectedPeers) { peer in
                        PeerRow(peer: peer, trailing: .connected)
                    }
                    if !session.connectedPeers.isEmpty {
                        Button("Disconnect from Everyone", role: .destructive) {
                            session.disconnectAll()
                        }
                    }
                }

                Section {
                    if session.nearbyPeers.isEmpty {
                        Text("Looking for people…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.nearbyPeers) { peer in
                        Button {
                            session.invite(peer.key)
                        } label: {
                            PeerRow(peer: peer, trailing: peer.isInvited || peer.connection == .connecting ? .waiting : .invite)
                        }
                        .disabled(peer.isInvited || peer.connection == .connecting)
                        .accessibilityHint("Sends a connection request")
                    }
                } header: {
                    HStack {
                        Text("Nearby")
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Searching")
                    }
                } footer: {
                    Text("Only people running CruiseLAN appear here. They must accept your request before you can chat.")
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
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func shouldShowTroubleshooting(at date: Date) -> Bool {
        guard session.connectedPeers.isEmpty, session.nearbyPeers.isEmpty else { return false }
        switch session.status {
        case .running(let since): return date.timeIntervalSince(since) > Self.troubleshootingDelay
        case .failed: return true
        case .idle: return false
        }
    }
}

struct PeerRow: View {
    enum Trailing { case connected, invite, waiting }

    let peer: SessionManager.RemotePeer
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Theme.teal)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(peer.shownName)
                .foregroundStyle(.primary)
            Spacer()
            switch trailing {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            case .invite:
                Text("Invite")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.teal)
            case .waiting:
                Text("Waiting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
            TipRow(symbol: "app.badge", text: "The other person must have CruiseLAN open in the foreground.")
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

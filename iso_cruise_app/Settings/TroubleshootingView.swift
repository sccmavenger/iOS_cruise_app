import SwiftUI
import UIKit

/// Self-service troubleshooting, so someone who can't see their friends can work out why
/// without having to ask anyone.
///
/// Before this, every reason for an empty People list looked the same on screen. The checks
/// here come from `ConnectivityDiagnosis`, which never reports a problem without also saying
/// what to do about it.
struct TroubleshootingView: View {
    @Environment(NetworkPathProbe.self) private var probe
    @Environment(SessionManager.self) private var session
    @Environment(\.openURL) private var openURL
    /// Nil in previews and demo builds, where the transport is faked.
    @Environment(\.lanTransport) private var lan
    @State private var showJoinCode = false
    @State private var wifiName = WiFiNameReader()
    @State private var networkTest = NetworkTest.shared
    @Environment(ConnectionSettings.self) private var connectionSettings

    @Environment(TelemetryStore.self) private var telemetry

    /// Where "Report a problem" files to. Public repo, so no credential is involved.
    private static let repository = "dannyguilloryjr/iso_cruise_app"

    private var diagnosis: ConnectivityDiagnosis {
        ConnectivityDiagnosis(conditions: probe.conditions, reach: lan?.diagnostics.verdict)
    }

    /// Links carried by the LAN transport right now, versus by radio. Splitting these is
    /// what answers "why do they vanish when I walk away": radio links have a hard range
    /// limit and network links don't.
    private var networkLinks: Int {
        session.linkMedia.filter { if case .localNetwork = $0 { true } else { false } }.count
    }
    private var radioLinks: Int { session.linkMedia.filter { $0 == .nearbyRadio }.count }

    private func isolationLabel(_ answer: LANDiagnostics.IsolationReading.Answer) -> String {
        switch answer {
        case .off: "not blocking"
        case .likelyOn: "probably on"
        case .inconclusive: "unclear"
        case .notTested: "checking…"
        }
    }

    private func isolationTint(_ answer: LANDiagnostics.IsolationReading.Answer) -> Color {
        switch answer {
        case .off: Theme.teal
        case .likelyOn: .red
        case .inconclusive, .notTested: .secondary
        }
    }

    private func tierRow(_ title: String, found: Int, unit: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: found > 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(found > 0 ? Theme.teal : .red)
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text("\(found) \(unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(found) \(unit). \(hint)")
    }

    /// The Wi-Fi network's name, read only after the user asks (it needs Location; see `WiFiNameReader`).
    @ViewBuilder
    private var wifiNameRow: some View {
        switch wifiName.state {
        case .notAsked:
            Button {
                wifiName.request()
            } label: {
                LabeledContent("Wi-Fi network") {
                    Text("Show name")
                }
            }
        case .checking:
            LabeledContent("Wi-Fi network") { ProgressView() }
        case .name(let ssid):
            LabeledContent("Wi-Fi network", value: ssid)
                .contextMenu {
                    Button("Check Again", systemImage: "arrow.clockwise") { wifiName.refresh() }
                }
        case .notOnWiFi:
            LabeledContent("Wi-Fi network", value: "Not on Wi-Fi")
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                LabeledContent("Wi-Fi network") {
                    Text("Allow Location to see it")
                }
            }
        }
    }

    /// Written fresh each time the page builds, so the file reflects what's on screen.
    private var reportURL: URL? {
        DiagnosticReport(
            telemetry: telemetry,
            conditions: probe.conditions,
            linkedCount: session.linkedCount,
            contactCount: session.knownIdentities.count,
            lan: lan?.diagnostics,
            nearbyRadioEnabled: connectionSettings.nearbyRadioEnabled,
            linkMedia: session.linkMedia,
            networkTest: networkTest,
            wifiName: { if case .name(let ssid) = wifiName.state { ssid } else { nil } }()
        ).writeToTemporaryFile()
    }

    var body: some View {
        List {
            Section {
                Text(diagnosis.headline)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

            Section {
                Button {
                    Task { await networkTest.run(lan: lan) }
                } label: {
                    HStack {
                        Label(networkTest.isRunning ? "Testing this network…" : "Run network test", systemImage: "stethoscope")
                        if networkTest.isRunning {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(networkTest.isRunning)
                if let verdict = networkTest.verdict {
                    Text(verdict)
                        .font(.callout)
                }
                if !networkTest.lines.isEmpty {
                    DisclosureGroup("Details (\(networkTest.lines.count) lines)") {
                        Text(networkTest.lines.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Network test")
            } footer: {
                Text("Takes about 20 seconds. Checks this phone's connection, the router, what other devices this network shows, whether broadcasts are allowed, and whether the other phone answers. Scan or type a friend's code first so it can test the path to them too. Everything stays on this network; nothing goes to the internet. The results are added to the report below.")
            }

            Section("Checks") {
                ForEach(diagnosis.checks) { check in
                    CheckRow(check: check) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            }

            Section {
                wifiNameRow
                LabeledContent("People linked right now", value: "\(session.linkedCount)")
                LabeledContent("Friends you can reach", value: "\(session.connectedIdentities.count)")
                LabeledContent("Links over short-range radio", value: "\(radioLinks)")
                LabeledContent("Links over this network", value: "\(networkLinks)")
            } header: {
                Text("Right now")
            } footer: {
                Text("\"Linked\" counts every CruiseLAN phone passing messages along for you, whether or not they're a friend. Radio links only reach about 10 metres; network links have no distance limit. To show the Wi-Fi name, iOS needs Location permission; CruiseLAN uses it only for that, and the name stays on this phone (it isn't in the report).")
            }

            if let lan {
                Section {
                    tierRow("Searching (Bonjour)", found: lan.diagnostics.bonjourPeersSeen,
                            unit: "phones", hint: "The normal way phones announce themselves.")
                    tierRow("Searching (broadcast)", found: lan.diagnostics.beaconsHeard,
                            unit: "signals", hint: "A backup for networks that hide the first method.")
                    tierRow("Connections made", found: lan.diagnostics.linksConnected,
                            unit: "links", hint: "Phones actually reached through this network.")
                    if lan.diagnostics.attemptsFailed > 0 {
                        LabeledContent("Attempts that failed", value: "\(lan.diagnostics.attemptsFailed)")
                            .font(.footnote)
                    }
                    if let address = lan.diagnostics.localAddress {
                        LabeledContent("This phone's address", value: address)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What this network allowed")
                } footer: {
                    Text("Zeros across the top two rows mean this network is stopping phones from finding each other, even though they're both online.")
                }
            }

            if let lan {
                Section {
                    Button {
                        showJoinCode = true
                    } label: {
                        Label("Scan a friend's code", systemImage: "qrcode.viewfinder")
                    }
                    let reading = lan.diagnostics.isolationReading
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Client isolation: \(isolationLabel(reading.answer))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isolationTint(reading.answer))
                        Text(reading.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("If nobody appears")
                } footer: {
                    Text("Some hotel and ship networks stop phones from finding each other even though they can still reach each other. Scanning a code skips the searching — and how that connection behaves is also the only way to tell whether this network is blocking phones at all.")
                }
            }

            Section {
                if let url = reportURL {
                    ShareLink(item: url) {
                        Label("Send a diagnostics file", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("Couldn't prepare the file.").foregroundStyle(.secondary)
                }
                if let issueURL = DiagnosticReport.githubIssueURL(repository: Self.repository) {
                    Link("Report a problem on GitHub", destination: issueURL)
                }
            } header: {
                Text("Send a report")
            } footer: {
                Text("The file has no messages, names, or locations in it — only counts and timings. You can open and read it before sending.")
            }

            Section("What needs what") {
                CapabilityMatrixView()
            }

            Section {
                ForEach(NetworkExplainer.points, id: \.title) { point in
                    DisclosureGroup(point.title) {
                        Text(point.body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("How CruiseLAN uses a network")
            } footer: {
                Text("CruiseLAN never uses the internet. It only talks to other phones.")
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showJoinCode) {
            if let lan { JoinByCodeView(lan: lan) }
        }
        .onAppear { probe.refresh() }
    }
}

private struct CheckRow: View {
    let check: ConnectivityDiagnosis.Check
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(check.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(check.state.label)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Text(check.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let action = check.action {
                Text(action)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                if check.opensSettings {
                    Button("Open Settings", action: openSettings)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.title): \(check.state.label). \(check.detail) \(check.action ?? "")")
    }

    private var symbol: String {
        switch check.state {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch check.state {
        case .good: Theme.teal
        case .warning: Theme.sunset
        case .bad: .red
        case .unknown: .secondary
        }
    }
}

/// The Wi-Fi / Bluetooth capability grid. Answers "what still works if one of them is off?"
private struct CapabilityMatrixView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ConnectivityDiagnosis.capabilityMatrix) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.feature)
                        .font(.footnote.weight(.semibold))
                    HStack(spacing: 12) {
                        support("Both", row.bothOn)
                        support("Wi-Fi", row.wifiOnly)
                        support("Bluetooth", row.bluetoothOnly)
                    }
                    Text(row.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(row.feature). With both: \(row.bothOn.rawValue). Wi-Fi only: \(row.wifiOnly.rawValue). Bluetooth only: \(row.bluetoothOnly.rawValue). \(row.note)"
                )
                if row.id != ConnectivityDiagnosis.capabilityMatrix.last?.id {
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func support(_ label: String, _ value: ConnectivityDiagnosis.CapabilityRow.Support) -> some View {
        HStack(spacing: 3) {
            Image(systemName: value == .yes ? "checkmark" : (value == .limited ? "minus" : "xmark"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(value == .yes ? Theme.teal : (value == .limited ? Theme.sunset : .red))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Plain-language answers to "it works on the local network — what does that actually mean?"
///
/// The cruise notes asked whether this is about Class A, B or C addressing. It isn't: classful
/// addressing was replaced by CIDR in 1993 and has nothing to do with whether two phones can
/// talk. What actually decides it is below.
enum NetworkExplainer {
    struct Point {
        let title: String
        let body: String
    }

    static let points: [Point] = [
        Point(
            title: "What \"local network\" means here",
            body: """
            CruiseLAN sends messages straight from your phone to your friend's phone over \
            whatever network you're both on. Nothing goes to the internet, and there's no \
            server in the middle — which is why it works at sea with no data package.
            """
        ),
        Point(
            title: "Is this about Class A, B or C networks?",
            body: """
            No. Those classes stopped being how addresses work in 1993, and they were never \
            what decided whether two devices could reach each other. What matters is whether \
            the network puts you both in the same group of addresses, and whether it's willing \
            to pass traffic between you at all. A network can give every cabin a perfectly \
            normal address and still refuse to let two of them talk.
            """
        ),
        Point(
            title: "Why some networks block it",
            body: """
            Hotel and ship Wi-Fi often turns on \"client isolation\", which stops guests' \
            devices from reaching each other on purpose — usually for security. Many also drop \
            the kind of \"shout to everyone\" message phones use to announce themselves. \
            Either one stops phones finding each other. When that happens, connecting with a \
            code can still work, because it skips the announcing entirely.
            """
        ),
        Point(
            title: "Why being far apart used to break it",
            body: """
            Without a usable network, phones fall back to talking radio-to-radio, which reaches \
            tens of metres at best and much less through a ship's steel decks. CruiseLAN passes \
            messages along through other people's phones to stretch that, but it can only hop \
            between people who are actually there. Using the ship's network removes the \
            distance limit altogether.
            """
        ),
        Point(
            title: "Do I need to buy the internet package?",
            body: """
            No. Joining the ship's Wi-Fi is enough, even if you never pay for internet and see \
            only the sign-in page. CruiseLAN just needs to be on the same network as your \
            friends.
            """
        ),
    ]
}

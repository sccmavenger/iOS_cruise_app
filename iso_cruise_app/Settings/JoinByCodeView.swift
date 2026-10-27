import SwiftUI

/// Connect two phones directly: one shows a QR code, the other scans it.
///
/// This is the last-resort tier, for networks that stop phones *finding* each other while
/// still letting them *reach* each other. Scanning replaced typing as the primary path
/// because reading eight characters across a table is error-prone and slow — but the typed
/// code is still shown underneath, because a camera in a dim bar is also unreliable and the
/// two failure modes don't overlap.
///
/// It doubles as the network test: how a direct connection *fails* is the only way an app on
/// iOS can tell client isolation from "nothing was there". See `LANDiagnostics`.
struct JoinByCodeView: View {
    let lan: LANTransport

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .show
    @State private var typed = ""
    @State private var problem: String?
    @State private var joined = false
    @State private var showScanner = false

    private enum Mode: String, CaseIterable {
        case show = "My Code"
        case scan = "Scan"
    }

    private var myCode: LANJoinCode? { lan.localJoinCode }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch mode {
                case .show: showSection
                case .scan: scanSection
                }

                resultSection
                networkTestSection
            }
            .navigationTitle("Connect Directly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerScreen { code in
                    connect(to: code)
                }
            }
        }
    }

    // MARK: - Showing

    @ViewBuilder
    private var showSection: some View {
        Section {
            if let myCode {
                VStack(spacing: 12) {
                    QRCodeView(payload: myCode.qrPayload)
                    Text(myCode.formatted)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel(spelledOut(myCode.formatted))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                Text("Join a Wi-Fi network to get a code.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Have your friend scan this")
        } footer: {
            Text("If the camera won't read it, they can type the letters underneath instead. Both do exactly the same thing.")
        }
    }

    // MARK: - Scanning

    @ViewBuilder
    private var scanSection: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("Open the camera", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
            .listRowBackground(Color.clear)
        } header: {
            Text("Scan your friend's code")
        } footer: {
            Text("The camera opens full screen so it's easier to aim.")
        }

        Section {
            TextField("ABCD-EFGH", text: $typed)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .onChange(of: typed) { _, _ in problem = nil }
            Button("Connect") {
                guard let code = LANJoinCode(code: typed) else {
                    problem = "That code isn't right. It should be eight letters and numbers."
                    joined = false
                    return
                }
                connect(to: code)
            }
            .disabled(typed.isEmpty)
        } header: {
            Text("Or type it")
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        if problem != nil || joined {
            Section {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else {
                    Label(
                        "Connecting. They'll appear in People in a moment, and you can send a connection request from there.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(Theme.teal)
                    .font(.footnote)
                }
            }
        }
    }

    // MARK: - Network test

    /// The payoff: after an attempt, say what the network actually did.
    @ViewBuilder
    private var networkTestSection: some View {
        let reading = lan.diagnostics.isolationReading
        if reading.answer != .notTested {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: reading.answer))
                        .foregroundStyle(tint(for: reading.answer))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline(for: reading.answer))
                            .font(.subheadline.weight(.semibold))
                        Text(reading.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Is this network blocking phones?")
            } footer: {
                Text("iOS gives apps no way to read a Wi-Fi network's settings, so this is worked out from how connections behave rather than read from the router.")
            }
        }
    }

    private func headline(for answer: LANDiagnostics.IsolationReading.Answer) -> String {
        switch answer {
        case .off: "No — this network passes traffic between phones"
        case .likelyOn: "Probably yes — guest devices look isolated"
        case .inconclusive: "Can't tell yet"
        case .notTested: ""
        }
    }

    private func symbol(for answer: LANDiagnostics.IsolationReading.Answer) -> String {
        switch answer {
        case .off: "checkmark.circle.fill"
        case .likelyOn: "xmark.circle.fill"
        case .inconclusive, .notTested: "questionmark.circle"
        }
    }

    private func tint(for answer: LANDiagnostics.IsolationReading.Answer) -> Color {
        switch answer {
        case .off: Theme.teal
        case .likelyOn: .red
        case .inconclusive, .notTested: .secondary
        }
    }

    // MARK: - Connecting

    private func connect(to code: LANJoinCode) {
        guard lan.join(using: code) else {
            problem = myCode?.encoded == code.encoded
                ? "That's your own code. Use your friend's instead."
                : "Couldn't start connecting. Check you're on a Wi-Fi network."
            joined = false
            return
        }
        problem = nil
        joined = true
    }

    /// VoiceOver reads "ABCD" as a word; spelling it out makes a code dictatable.
    private func spelledOut(_ code: String) -> String {
        code.map { $0 == "-" ? "dash" : String($0) }.joined(separator: " ")
    }
}

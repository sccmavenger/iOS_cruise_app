import SwiftUI

/// The admin surface: every telemetry signal, grouped by the question it answers, plus an
/// overall performance read.
///
/// Organised by question rather than by counter on purpose — the brief was that each signal
/// must answer a question, and a page that just lists numbers makes it easy for an orphan
/// metric to hide. If a number appears here, the question above it says why it exists.
///
/// Everything shown is from **this device only**. Uploaded data is read with SQL against the
/// backend; see server/telemetry-worker/README.md.
struct InsightsView: View {
    @Environment(TelemetryStore.self) private var telemetry
    @State private var showEraseConfirmation = false

    private var report: PerformanceReport {
        PerformanceReport(store: telemetry)
    }

    var body: some View {
        @Bindable var telemetry = telemetry
        List {
            Section {
                NavigationLink {
                    PerformanceView()
                } label: {
                    LabeledContent("Performance") {
                        Text(report.overall.label)
                            .foregroundStyle(grade: report.overall)
                    }
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Measured since \(telemetry.windowStart.formatted(date: .abbreviated, time: .shortened)).")
            }

            ForEach(TelemetryQuestion.allCases, id: \.self) { question in
                Section {
                    ForEach(question.signals, id: \.self) { signal in
                        SignalRow(signal: signal)
                    }
                } header: {
                    Text(question.text)
                        .textCase(nil)
                        .font(.footnote)
                }
            }

            Section {
                Toggle("Share anonymous diagnostics", isOn: $telemetry.isSharingEnabled)
                Button("Delete collected data", role: .destructive) {
                    showEraseConfirmation = true
                }
            } header: {
                Text("Sharing")
            } footer: {
                Text("""
                These numbers stay on your phone unless you turn sharing on. They never include \
                messages, nicknames, who you talked to, or where you were — only counts and \
                timings, grouped under a label that changes every two weeks.
                """)
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete everything collected on this phone?",
            isPresented: $showEraseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { telemetry.eraseAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears all measurements and starts a new anonymous label.")
        }
    }
}

/// One signal with its breakdown by dimension.
private struct SignalRow: View {
    @Environment(TelemetryStore.self) private var telemetry
    let signal: TelemetrySignal

    private var breakdown: [(dimension: TelemetryDimension?, aggregate: TelemetryStore.Aggregate)] {
        telemetry.breakdown(of: signal)
    }

    var body: some View {
        if breakdown.isEmpty {
            LabeledContent(signal.title) {
                Text("—").foregroundStyle(.tertiary)
            }
        } else {
            DisclosureGroup {
                ForEach(breakdown, id: \.dimension) { entry in
                    LabeledContent(entry.dimension?.label ?? "All") {
                        Text(value(for: entry.aggregate))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            } label: {
                LabeledContent(signal.title) {
                    Text(headline)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var headline: String {
        let total = telemetry.total(signal)
        guard signal.unit.isDistribution else { return "\(total)" }
        let combined = breakdown.reduce(into: (sum: 0.0, count: 0)) { result, entry in
            result.sum += entry.aggregate.sum
            result.count += entry.aggregate.count
        }
        guard combined.count > 0 else { return "—" }
        let average = combined.sum / Double(combined.count)
        return signal.unit == .seconds
            ? "avg \(format(average))s"
            : "avg \(String(format: "%.1f", average))"
    }

    private func value(for aggregate: TelemetryStore.Aggregate) -> String {
        switch signal.unit {
        case .occurrences:
            "\(aggregate.count)"
        case .seconds:
            "n=\(aggregate.count) avg \(format(aggregate.average))s max \(format(aggregate.highest))s"
        case .count:
            "n=\(aggregate.count) avg \(String(format: "%.1f", aggregate.average)) max \(Int(aggregate.highest))"
        }
    }

    private func format(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.2f", seconds) : String(format: "%.0f", seconds)
    }
}

/// The "how is the app doing overall" view, one finding per question.
struct PerformanceView: View {
    @Environment(TelemetryStore.self) private var telemetry
    @Environment(\.openURL) private var openURL

    private var report: PerformanceReport {
        PerformanceReport(store: telemetry)
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Overall") {
                    Text(report.overall.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(grade: report.overall)
                }
            } footer: {
                Text("The overall read follows the worst area, not the average: people who can't connect aren't helped by games running smoothly.")
            }

            ForEach(report.findings) { finding in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(finding.grade.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(grade: finding.grade)
                            Spacer()
                        }
                        Text(finding.summary)
                            .font(.footnote)
                        Text(finding.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                } header: {
                    Text(finding.question.text)
                        .textCase(nil)
                        .font(.footnote)
                }
            }

            Section {
                Text("Crashes aren't counted here. Xcode's Organizer already reports them for TestFlight and App Store builds, and duplicating that would mean collecting more than this needs to.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Not measured here")
            }
        }
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension View {
    /// Consistent colouring for a grade, so Good never reads as a warning anywhere.
    func foregroundStyle(grade: PerformanceReport.Grade) -> some View {
        let colour: Color = switch grade {
        case .good: Theme.teal
        case .fair: Theme.sunset
        case .poor: .red
        case .unknown: .secondary
        }
        return foregroundStyle(colour)
    }
}

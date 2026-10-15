import SwiftUI

/// Group chat with every connected peer.
struct ChatView: View {
    @Environment(SessionManager.self) private var session
    @State private var draft = ""
    @State private var showPeers = false
    @State private var showProfile = false
    @State private var sendFailed = false
    @State private var filterNotice: String?
    @State private var reportTarget: ReportTarget?
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBanner { showPeers = true }

                if session.chat.messages.isEmpty {
                    ScrollView {
                        IllustratedMessage(
                            title: session.connectedPeers.isEmpty ? "No one connected yet" : "Say hello!",
                            message: session.connectedPeers.isEmpty
                                ? "Tap People to find nearby CruiseLAN users and invite them to chat."
                                : "Messages go to everyone you're connected with and aren't saved."
                        )
                        .padding(.top, 24)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onTapGesture { composerFocused = false }
                } else {
                    MessageList(
                        messages: session.chat.messages,
                        onReport: { reportTarget = $0 },
                        onBlock: { session.block(identityId: $0.senderId) }
                    )
                    .onTapGesture { composerFocused = false }
                }

                if let filterNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "hand.raised.fill").accessibilityHidden(true)
                        Text(filterNotice)
                    }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.coral, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }

                ComposerBar(draft: $draft, canSend: !session.connectedIdentities.isEmpty, isFocused: $composerFocused) {
                    switch session.sendChat(draft) {
                    case .sent:
                        draft = ""
                        withAnimation { filterNotice = nil }
                    case .filtered(let reason):
                        // Keep the draft so they can fix it; explain kindly.
                        withAnimation { filterNotice = reason.message }
                    case .noRecipients:
                        sendFailed = true
                    case .empty:
                        break
                    }
                }
                .onChange(of: draft) { _, _ in
                    if filterNotice != nil { withAnimation { filterNotice = nil } }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Profile", systemImage: "person.crop.circle") { showProfile = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("People", systemImage: "person.2.wave.2.fill") { showPeers = true }
                }
            }
            .sheet(isPresented: $showPeers) { PeersView() }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .sheet(item: $reportTarget) { target in
                ReportView(target: target)
            }
            .alert("Message not sent", isPresented: $sendFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("No one is connected right now. Check the People list and try again.")
            }
        }
    }
}

/// One-line connection summary at the top of the chat.
struct ConnectionBanner: View {
    @Environment(SessionManager.self) private var session
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .symbolEffect(.variableColor.iterative, isActive: isSearching)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 6)
        .accessibilityHint("Shows nearby people")
    }

    private var isSearching: Bool {
        if case .running = session.status, session.connectedPeers.isEmpty { return true }
        return false
    }

    private var symbol: String {
        switch session.status {
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "pause.circle"
        case .running: session.connectedPeers.isEmpty ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch session.status {
        case .failed: .orange
        case .idle: .secondary
        case .running: session.connectedPeers.isEmpty ? Theme.teal : .green
        }
    }

    private var text: String {
        switch session.status {
        case .failed: return "Couldn't start nearby search"
        case .idle: return "Not searching"
        case .running:
            let connected = session.connectedPeers.count
            if connected > 0 { return connected == 1 ? "Connected to 1 person" : "Connected to \(connected) people" }
            let nearby = session.nearbyPeers.count
            if nearby > 0 { return nearby == 1 ? "1 person nearby — tap to connect" : "\(nearby) people nearby — tap to connect" }
            return "Searching for people nearby…"
        }
    }
}

struct MessageList: View {
    let messages: [ChatStore.Message]
    var onReport: (ReportTarget) -> Void = { _ in }
    var onBlock: (ChatStore.Message) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                            .contextMenu {
                                if message.kind == .text, !message.isLocal {
                                    Button("Report…", systemImage: "exclamationmark.bubble") {
                                        onReport(ReportTarget(identityId: message.senderId, name: message.senderName, message: message.text))
                                    }
                                    Button("Block \(message.senderName)", systemImage: "hand.raised", role: .destructive) {
                                        onBlock(message)
                                    }
                                }
                            }
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

struct MessageRow: View {
    let message: ChatStore.Message

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .text:
            HStack {
                if message.isLocal { Spacer(minLength: 48) }
                VStack(alignment: message.isLocal ? .trailing : .leading, spacing: 3) {
                    if !message.isLocal {
                        Text("\(message.senderName) #\(message.senderTag)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(message.isLocal ? Color.white : Color.primary)
                        .background(
                            message.isLocal ? AnyShapeStyle(Theme.teal) : AnyShapeStyle(.fill.secondary),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .textSelection(.enabled)
                    Text(message.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !message.isLocal { Spacer(minLength: 48) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message.isLocal ? "You said \(message.text)" : "\(message.senderName) said \(message.text)")
        }
    }
}

struct ComposerBar: View {
    @Binding var draft: String
    let canSend: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(canSend ? "Message" : "Connect to someone to chat", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .focused(isFocused)
                .disabled(!canSend)
                .onChange(of: draft) { _, newValue in
                    if newValue.count > EnvelopeCodec.maxChatCharacters {
                        draft = String(newValue.prefix(EnvelopeCodec.maxChatCharacters))
                    }
                }

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend || trimmed.isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

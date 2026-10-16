import SwiftUI

/// The Chat tab: "Everyone", one-on-one chats, and groups.
struct ChatView: View {
    @Environment(SessionManager.self) private var session
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app
    @State private var showPeers = false
    @State private var showProfile = false
    @State private var showNewChat = false

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.chatPath) {
            VStack(spacing: 0) {
                ConnectionBanner { showPeers = true }
                List {
                    ForEach(session.chat.sortedConversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(conversation: conversation)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            if conversation.kind != .everyone {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    session.chat.delete(conversation.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                // A fresh view per chat, so drafts and notices don't carry over between chats.
                ConversationView(conversationId: id)
                    .id(id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Profile", systemImage: "person.crop.circle") { showProfile = true }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("People", systemImage: "person.2.wave.2.fill") { showPeers = true }
                    Button("New Chat", systemImage: "square.and.pencil") { showNewChat = true }
                        .disabled(session.reachableIdentities.isEmpty)
                }
            }
            .sheet(isPresented: $showPeers) { PeersView() }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .sheet(isPresented: $showNewChat) { NewChatView() }
            .onChange(of: app.sheetDismissals) {
                // The game screen is about to appear; sheets would block it.
                showPeers = false
                showProfile = false
                showNewChat = false
            }
        }
    }
}

/// One conversation in the list: who it's with, the latest message, and unread count.
struct ConversationRow: View {
    let conversation: ChatStore.Conversation
    @Environment(SessionManager.self) private var session

    private var title: String { session.chat.title(of: conversation, localId: session.localId) }
    private var unread: Int { session.chat.unread[conversation.id] ?? 0 }

    private var symbol: String {
        switch conversation.kind {
        case .everyone: "person.3.fill"
        case .direct: "person.fill"
        case .group: "person.2.fill"
        }
    }

    private var subtitle: String {
        if let last = session.chat.lastMessage(in: conversation.id) {
            return last.isLocal ? "You: \(last.text)" : (conversation.kind == .direct ? last.text : "\(last.senderName): \(last.text)")
        }
        return conversation.kind == .everyone ? "Everyone you're connected to" : "No messages yet"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(conversation.kind == .everyone ? Theme.teal : Theme.deep, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let last = session.chat.lastMessage(in: conversation.id) {
                        Text(last.date, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.coral, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)\(unread > 0 ? ", \(unread) unread" : "")")
    }
}

/// Messages and the composer for one conversation.
struct ConversationView: View {
    let conversationId: UUID
    @Environment(SessionManager.self) private var session
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @State private var sendFailed = false
    @State private var filterNotice: String?
    @State private var reportTarget: ReportTarget?
    @FocusState private var composerFocused: Bool

    private var conversation: ChatStore.Conversation? { session.chat.conversation(conversationId) }

    var body: some View {
        let messages = session.chat.messages(in: conversationId)
        VStack(spacing: 0) {
            if messages.isEmpty {
                ScrollView {
                    IllustratedMessage(title: emptyTitle, message: emptyMessage)
                        .padding(.top, 24)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { composerFocused = false }
            } else {
                MessageList(
                    messages: messages,
                    showsSender: conversation?.kind != .direct,
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

            // People who stepped away still get messages: held until they're back, with a nudge now.
            ComposerBar(draft: $draft, canSend: session.canChat(in: conversationId),
                        onlyAway: !session.hasConnectedMembers(in: conversationId),
                        unavailableText: unavailableText, isFocused: $composerFocused) {
                switch session.sendChat(draft, in: conversationId) {
                case .sent:
                    draft = ""
                    withAnimation { filterNotice = nil }
                case .filtered(let reason):
                    // Keep the draft so they can fix it; explain kindly.
                    withAnimation { filterNotice = reason.message }
                    AccessibilityNotification.Announcement(reason.message).post()
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
        .navigationTitle(conversation.map { session.chat.title(of: $0, localId: session.localId) } ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let conversation, conversation.kind == .group {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Members", systemImage: "person.2") {
                        ForEach(conversation.members, id: \.id) { member in
                            Text(member.id == session.localId ? "\(member.nickname) (you)" : member.nickname)
                        }
                    }
                }
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportView(target: target)
        }
        .onChange(of: app.sheetDismissals) { reportTarget = nil }
        .alert("Message not sent", isPresented: $sendFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No one in this chat is connected or nearby right now.")
        }
    }

    /// Placeholder when nobody in this chat can be reached.
    private var unavailableText: String {
        guard let conversation, conversation.kind == .direct else { return "Connect to someone to chat" }
        return "\(session.chat.title(of: conversation, localId: session.localId)) isn't nearby right now"
    }

    private var emptyTitle: String {
        guard let conversation else { return "Chat" }
        switch conversation.kind {
        case .everyone: return session.canChat ? "Say hello!" : "No one connected yet"
        case .direct, .group: return "Start the conversation"
        }
    }

    private var emptyMessage: String {
        guard let conversation else { return "" }
        switch conversation.kind {
        case .everyone:
            return session.canChat
                ? "Messages here go to everyone you're connected with and aren't saved."
                : "Tap People to find nearby CruiseLAN users and invite them to chat."
        case .direct:
            return "Only you and \(session.chat.title(of: conversation, localId: session.localId)) see these messages."
        case .group:
            return "Only the people in this group see these messages."
        }
    }
}

/// Pick one person for a one-on-one chat, or several for a group.
struct NewChatView: View {
    @Environment(SessionManager.self) private var session
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var groupName = ""

    private var people: [PeerIdentity] { session.reachableIdentities }
    private var chosen: [PeerIdentity] { people.filter { selected.contains($0.id) } }
    private var isFull: Bool { chosen.count >= ConversationRef.maxMembers - 1 }

    /// Explains why a typed group name won't be used.
    private var nameProblem: String? {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, case .blocked(let reason) = session.filter.check(trimmed) else { return nil }
        return reason.message
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(people, id: \.id) { person in
                        Button {
                            if selected.contains(person.id) {
                                selected.remove(person.id)
                            } else if !isFull {
                                selected.insert(person.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(person.id) ? Theme.teal : .secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(person.labeledName).foregroundStyle(.primary)
                                    if !session.isConnected(person.id) {
                                        Text("Away").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(isFull && !selected.contains(person.id))
                        .accessibilityAddTraits(selected.contains(person.id) ? .isSelected : [])
                    }
                } header: {
                    Text(chosen.isEmpty ? "People nearby" : "People nearby · \(chosen.count) of \(ConversationRef.maxMembers - 1) picked")
                } footer: {
                    Text("Pick one person for a private chat, or up to \(ConversationRef.maxMembers - 1) for a group. Only the people you pick see the messages.")
                }

                if chosen.count >= 2 {
                    Section {
                        TextField("e.g. Pool Crew", text: $groupName)
                            .textInputAutocapitalization(.words)
                            .onChange(of: groupName) { _, value in
                                if value.count > ConversationRef.maxNameLength {
                                    groupName = String(value.prefix(ConversationRef.maxNameLength))
                                }
                            }
                    } header: {
                        Text("Group name (optional)")
                    } footer: {
                        if let nameProblem {
                            Text("\(nameProblem) The group will be named after its members instead.")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.count >= 2 ? "Create Group" : "Start") { start() }
                        .disabled(chosen.isEmpty)
                }
            }
            // Someone who drops out of reach while picked shouldn't still count.
            .onChange(of: people.map(\.id)) { _, ids in
                selected.formIntersection(ids)
            }
        }
    }

    private func start() {
        guard !chosen.isEmpty else { return }
        let conversation = chosen.count == 1
            ? session.directConversation(with: chosen[0])
            : session.createGroup(name: groupName, with: chosen)
        dismiss()
        app.open(conversation: conversation.id)
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
        if case .running = session.status, session.connectedIdentities.isEmpty { return true }
        return false
    }

    private var awayCount: Int { session.awayIdentityIds.count }

    private var symbol: String {
        switch session.status {
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "pause.circle"
        case .running:
            if !session.invitations.isEmpty { "person.crop.circle.badge.questionmark" }
            else { session.connectedIdentities.isEmpty ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill" }
        }
    }

    private var tint: Color {
        switch session.status {
        case .failed: .orange
        case .idle: .secondary
        case .running: session.connectedIdentities.isEmpty ? Theme.teal : .green
        }
    }

    private var text: String {
        switch session.status {
        case .failed: return "Couldn't start nearby search"
        case .idle: return "Not searching"
        case .running:
            let requests = session.invitations.count
            if requests > 0 { return requests == 1 ? "1 person wants to connect" : "\(requests) people want to connect" }
            let connected = session.connectedIdentities.count
            let away = awayCount > 0 ? " · \(awayCount) away" : ""
            if connected > 0 { return (connected == 1 ? "Connected to 1 person" : "Connected to \(connected) people") + away }
            if awayCount > 0 { return awayCount == 1 ? "Reconnecting… 1 person away" : "Reconnecting… \(awayCount) people away" }
            let nearby = session.discoveredPeople.count
            if nearby > 0 { return nearby == 1 ? "1 person nearby — tap to connect" : "\(nearby) people nearby — tap to connect" }
            return "Searching for people nearby…"
        }
    }
}

struct MessageList: View {
    let messages: [ChatStore.Message]
    /// Hidden in one-on-one chats, where every message is from the same person.
    var showsSender = true
    var onReport: (ReportTarget) -> Void = { _ in }
    var onBlock: (ChatStore.Message) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageRow(message: message, showsSender: showsSender)
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
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.immediately)
            .task {
                // Open at the newest message. The lazy stack hasn't measured its rows on the
                // first pass, so scroll again once layout has settled.
                guard let last = messages.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

struct MessageRow: View {
    let message: ChatStore.Message
    var showsSender = true

    /// For a message waiting for someone who's away, including what Bluetooth managed.
    private var heldText: String {
        switch message.deliveryNote {
        case .notified: "Waiting to send · they were notified"
        case .unreachable: "Waiting to send · their phone didn't answer by Bluetooth"
        case .bluetooth, nil: "Waiting to send"
        }
    }

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
                    if !message.isLocal, showsSender {
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
                    if message.isHeld {
                        Label(heldText, systemImage: message.deliveryNote == .unreachable ? "exclamationmark.circle" : "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if message.deliveryNote == .bluetooth {
                        Label("Delivered by Bluetooth", systemImage: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(message.date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
    /// Everyone is away: the message is held for them and they get a nudge.
    var onlyAway = false
    var unavailableText = "Connect to someone to chat"
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(canSend ? (onlyAway ? "Message (sent when they're back)" : "Message") : unavailableText, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .focused(isFocused)
                .disabled(!canSend)
                .onChange(of: draft) { oldValue, newValue in
                    // Return sends, even when it arrives with other typed text in one change.
                    // Line breaks inside pasted text are kept.
                    if newValue.hasSuffix("\n"), !oldValue.hasSuffix("\n") {
                        var text = newValue
                        while text.last?.isNewline == true { text.removeLast() }
                        draft = text
                        if canSend, !trimmed.isEmpty { onSend() }
                        return
                    }
                    if newValue.count > EnvelopeCodec.maxChatCharacters {
                        draft = String(newValue.prefix(EnvelopeCodec.maxChatCharacters))
                    }
                }
                .submitLabel(.send)

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

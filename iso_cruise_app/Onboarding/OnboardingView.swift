import SwiftUI

/// First-run screen: explains what CruiseLAN does and asks for a temporary nickname.
struct OnboardingView: View {
    @Environment(ProfileStore.self) private var profile
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var sanitized: String? { Nickname.sanitize(name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image("Hero")
                    .resizable()
                    .scaledToFill()
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to CruiseLAN")
                        .font(.largeTitle.bold())
                    Text("Chat and play games with people nearby — no internet needed.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    FeatureRow(symbol: "wifi.slash", title: "Works offline", detail: "Connects directly to nearby iPhones over Wi-Fi or Bluetooth.")
                    FeatureRow(symbol: "lock.fill", title: "Private by design", detail: "Encrypted links, no accounts, no cloud. Messages vanish when you quit.")
                    FeatureRow(symbol: "gamecontroller.fill", title: "Play together", detail: "Tic-Tac-Toe, Connect Four, and Color Match.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick a nickname")
                        .font(.headline)
                    TextField("e.g. Captain Sam", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($nameFocused)
                        .onSubmit(save)
                    Text("Shown to people nearby. Up to \(Nickname.maxCharacters) characters. You can change it later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Next, iOS will ask to find devices on your local network. CruiseLAN needs this to discover nearby people.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        // Pinned above the keyboard so it's always reachable while typing.
        .safeAreaInset(edge: .bottom) {
            Button(action: save) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(sanitized == nil)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private func save() {
        guard sanitized != nil else { return }
        profile.setNickname(name)
    }
}

struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.teal)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView()
        .environment(ProfileStore(defaults: UserDefaults(suiteName: "preview")!))
}

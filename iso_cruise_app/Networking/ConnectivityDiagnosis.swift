import Foundation

/// Turns `NetworkPathProbe.Conditions` into something a user can act on.
///
/// The troubleshooting page renders this directly. Each `Check` states what was tested, what
/// the answer was, and — when it's not good news — exactly what to do, in the user's own
/// terms. No check says "failed" without saying what to do about it.
struct ConnectivityDiagnosis {
    enum State: Sendable {
        case good
        case warning
        case bad
        case unknown

        var label: String {
            switch self {
            case .good: "Working"
            case .warning: "Limited"
            case .bad: "Not working"
            case .unknown: "Unknown"
            }
        }
    }

    struct Check: Identifiable, Sendable {
        let id: String
        let title: String
        let state: State
        /// What this means, in plain language.
        let detail: String
        /// What to do about it. Nil when nothing needs doing.
        let action: String?
        /// Whether `action` is something Settings can fix, so the page can offer a shortcut.
        var opensSettings = false
    }

    let checks: [Check]
    let conditions: NetworkPathProbe.Conditions

    /// The single most useful sentence for someone who can't see their friends.
    var headline: String {
        if conditions.isOffline && !conditions.bluetooth.isUsable {
            return "No connection. Turn on Wi-Fi or Bluetooth to find people."
        }
        if conditions.isLocalNetworkDenied {
            return "CruiseLAN can't reach the ship's network. Allow Local Network access to find people further away."
        }
        if !conditions.canUseLAN && conditions.bluetooth.isUsable {
            return "Short range only. You'll find people nearby, but not across the ship."
        }
        if conditions.isLowPowerMode {
            return "Low Power Mode is on, which can make friends slower to appear."
        }
        // Being *on* a network is not the same as that network letting two phones talk, and
        // claiming otherwise is exactly the misleading reassurance this page exists to avoid.
        // `reach` carries the answer once the LAN tiers have actually been tried.
        switch reach {
        case .blocked:
            return "This network won't pass messages between phones. You'll only find people close by."
        case .codeOnly:
            return "This network blocks searching, but connecting with a code works."
        case .broadcastOnly, .discoveryWorks:
            return "Connected through the network. You can reach people anywhere it covers."
        case .cannotListen:
            return "CruiseLAN can't open a connection on this network."
        case .looking, .notStarted, nil:
            return conditions.canUseLAN
                ? "On a network. Still checking whether it lets phones talk to each other."
                : "Looking for people nearby."
        }
    }

    /// What the LAN tiers actually managed, when a LAN transport is running.
    let reach: LANDiagnostics.Verdict?

    init(conditions: NetworkPathProbe.Conditions, reach: LANDiagnostics.Verdict? = nil) {
        self.conditions = conditions
        self.reach = reach
        var checks: [Check] = []

        checks.append(Check(
            id: "wifi",
            title: "Wi-Fi",
            state: conditions.hasWiFi ? .good : .bad,
            detail: conditions.hasWiFi
                ? "Connected. This is what lets CruiseLAN reach people beyond the room you're in."
                : "Not connected. Without Wi-Fi, CruiseLAN can only use Bluetooth, which reaches about 10 metres.",
            action: conditions.hasWiFi ? nil : "Join the ship's Wi-Fi network. You don't need to buy an internet package — CruiseLAN only uses the network to talk to other phones on the ship.",
            opensSettings: !conditions.hasWiFi
        ))

        checks.append(Check(
            id: "localNetwork",
            title: "Local Network access",
            state: conditions.isLocalNetworkDenied ? .bad : (conditions.hasWiFi ? .good : .unknown),
            detail: conditions.isLocalNetworkDenied
                ? "Denied. iOS is blocking CruiseLAN from seeing other phones on this network, so only Bluetooth is left."
                : "Allowed. CruiseLAN can look for other phones on this network.",
            action: conditions.isLocalNetworkDenied
                ? "Open Settings › CruiseLAN and turn on Local Network. This is the most common reason people can't see each other."
                : nil,
            opensSettings: conditions.isLocalNetworkDenied
        ))

        let bluetoothState: State = switch conditions.bluetooth {
        case .ready: .good
        case .poweredOff, .unauthorized: .bad
        case .unsupported: .bad
        case .unknown: .unknown
        }
        let bluetoothDetail = switch conditions.bluetooth {
        case .ready: "On. CruiseLAN can find people close by, and can wake your phone for a message while it's locked."
        case .poweredOff: "Off. People very close by are harder to find, and your phone won't light up for a message while it's locked."
        case .unauthorized: "Not permitted. CruiseLAN can't use Bluetooth at all."
        case .unsupported: "Not available on this device."
        case .unknown: "Not determined yet."
        }
        let bluetoothAction: String? = switch conditions.bluetooth {
        case .poweredOff: "Turn Bluetooth on in Control Centre or Settings."
        case .unauthorized: "Open Settings › CruiseLAN and turn on Bluetooth."
        case .ready, .unsupported, .unknown: nil
        }
        checks.append(Check(
            id: "bluetooth",
            title: "Bluetooth",
            state: bluetoothState,
            detail: bluetoothDetail,
            action: bluetoothAction,
            opensSettings: conditions.bluetooth == .unauthorized
        ))

        checks.append(Check(
            id: "lowPower",
            title: "Low Power Mode",
            state: conditions.isLowPowerMode ? .warning : .good,
            detail: conditions.isLowPowerMode
                ? "On. iOS reduces background radio work in Low Power Mode, so friends can take longer to appear and may drop sooner."
                : "Off. CruiseLAN can look for people at full speed.",
            action: conditions.isLowPowerMode
                ? "If people aren't appearing, try turning Low Power Mode off in Settings › Battery."
                : nil,
            opensSettings: conditions.isLowPowerMode
        ))

        // The decisive check: did the network actually carry anything between phones? This
        // is what tells "far apart stopped working" apart from everything above, all of
        // which can read as fine on a network with client isolation.
        if let reach {
            let state: State = switch reach {
            case .discoveryWorks, .broadcastOnly: .good
            case .codeOnly: .warning
            case .blocked, .cannotListen: .bad
            case .looking, .notStarted: .unknown
            }
            let reachDetail = switch reach {
            case .discoveryWorks:
                "Working. CruiseLAN found other phones through this network, so distance isn't a limit."
            case .broadcastOnly:
                "Working. This network hides the usual way phones announce themselves, but CruiseLAN found another way through."
            case .codeOnly:
                "Partly. Searching doesn't work on this network, but connecting with a code does."
            case .blocked:
                "Not working. This network is carrying nothing between phones, so CruiseLAN can only use its short-range radio — which is why people disappear when you walk away."
            case .cannotListen:
                "CruiseLAN couldn't start listening for connections on this network."
            case .looking:
                "Still checking. Give it a few seconds."
            case .notStarted:
                "Not started yet."
            }
            let reachAction: String? = switch reach {
            case .blocked:
                "Try \"Connect with a code\" below. If that works, it's only searching that's blocked. If it doesn't, this network separates every guest device on purpose and no app can reach across it — you'll need to stay within about 10 metres of each other, or share a personal hotspot that you both join."
            case .codeOnly:
                "Use \"Connect with a code\" to reach people who are far away."
            case .discoveryWorks, .broadcastOnly, .cannotListen, .looking, .notStarted:
                nil
            }
            checks.append(Check(
                id: "reach",
                title: "Reaching people through this network",
                state: state,
                detail: reachDetail,
                action: reachAction
            ))
        }

        // A hotspot is a private network with no client isolation, so CruiseLAN always works
        // across one. Worth saying out loud: it's the answer to the blocked case above, and
        // a user already on one shouldn't be left wondering.
        let hotspot = LANAddress.hotspotRole()
        if hotspot != .none {
            checks.append(Check(
                id: "hotspot",
                title: "Personal Hotspot",
                state: .good,
                detail: hotspot == .sharing
                    ? "You're sharing a hotspot. Anyone who joins it can always reach you, whatever the hotel's Wi-Fi does."
                    : "You're on someone's hotspot. Everyone on it can always reach each other.",
                action: nil
            ))
        } else if reach == .blocked {
            checks.append(Check(
                id: "hotspotSuggestion",
                title: "A way around this network",
                state: .warning,
                detail: "A Personal Hotspot is your own private network, so nothing can block phones on it from reaching each other.",
                action: "Have one person turn on Personal Hotspot in Settings, and everyone else join it instead of the hotel Wi-Fi. It uses their mobile data allowance only if you're also browsing the internet — CruiseLAN itself doesn't.",
                opensSettings: true
            ))
        }

        if conditions.isConstrained {
            checks.append(Check(
                id: "lowData",
                title: "Low Data Mode",
                state: .warning,
                detail: "On for this network. iOS limits background traffic, which can slow discovery.",
                action: "Turn Low Data Mode off for this network in Settings › Wi-Fi.",
                opensSettings: true
            ))
        }

        self.checks = checks
    }

    /// Answers "what works with Wi-Fi but no Bluetooth, and the other way round?" — the
    /// question in the cruise notes. Kept as data rather than prose so the troubleshooting
    /// page and the decision record can't drift apart.
    ///
    /// The reasoning behind each row:
    /// - Short-range discovery works over either radio, because MultipeerConnectivity picks
    ///   whichever it has. Bluetooth alone is roughly 10 m; peer-to-peer Wi-Fi reaches
    ///   further and carries far more data.
    /// - Shipwide discovery needs an actual network, so it needs Wi-Fi. Bluetooth can never
    ///   do it, no matter how many phones relay.
    /// - Waking a locked phone is Bluetooth-only: it's `NudgeService` doing it, and the
    ///   background mode CruiseLAN holds is `bluetooth-peripheral`. Wi-Fi can't wake a
    ///   suspended app this way.
    static let capabilityMatrix: [CapabilityRow] = [
        CapabilityRow(
            feature: "Find people in the same room",
            bothOn: .yes, wifiOnly: .yes, bluetoothOnly: .yes, neither: .no,
            note: "Either radio can do this on its own."
        ),
        CapabilityRow(
            feature: "Find people across the ship",
            bothOn: .yes, wifiOnly: .yes, bluetoothOnly: .no, neither: .no,
            note: "Needs the ship's network. Bluetooth has no path beyond the people relaying for you."
        ),
        CapabilityRow(
            feature: "Chat and play games",
            bothOn: .yes, wifiOnly: .yes, bluetoothOnly: .limited, neither: .no,
            note: "Works with anyone you can reach. On Bluetooth alone that means people close by."
        ),
        CapabilityRow(
            feature: "Wake your phone for a message while locked",
            bothOn: .yes, wifiOnly: .no, bluetoothOnly: .yes, neither: .no,
            note: "This is Bluetooth doing the waking; Wi-Fi can't start the app in the background."
        ),
        CapabilityRow(
            feature: "Keep playing when someone walks away",
            bothOn: .yes, wifiOnly: .limited, bluetoothOnly: .limited, neither: .no,
            note: "Messages are held and delivered when they're back in reach, whichever radio brings them back."
        ),
    ]

    struct CapabilityRow: Identifiable, Sendable {
        let feature: String
        let bothOn: Support
        let wifiOnly: Support
        let bluetoothOnly: Support
        let neither: Support
        let note: String

        var id: String { feature }

        enum Support: String, Sendable {
            case yes = "Yes"
            case limited = "Limited"
            case no = "No"
        }
    }
}

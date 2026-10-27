#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Plays seeded games through `Bridge.handle` and records every request and response, so the
/// WebAssembly build can be checked byte-for-byte against the native build.
public enum GoldenTrace {
    public static func generate(gamesPerType: Int, maxSteps: Int) -> [String] {
        var lines: [String] = []
        for type in GameType.allCases {
            for game in 0..<gamesPerType {
                var driver = SplitMix64(seed: UInt64(1_000 + game))
                let seats = (0..<type.maxPlayers).map { "seat\($0)" }
                var seed = driver.next() >> 11
                let newRequest = #"{"op":"new","game":"\#(type.rawValue)","seats":\#(json(seats)),"seed":"\#(seed)"}"#
                var response = Bridge.handle(newRequest)
                lines.append(record(newRequest, response))
                guard var state = decodeState(response) else { continue }
                var steps = 0
                while !state.isFinished && steps < maxSteps {
                    steps += 1
                    let awaiting = awaitingSeats(response)
                    guard let actor = awaiting.first else { break }
                    var applied = false
                    var rejectedRecorded = 0
                    for move in candidates(state).shuffled(using: &driver) {
                        seed = driver.next() >> 11
                        let request = #"{"op":"apply","state":\#(json(state)),"seat":"\#(actor)","move":\#(json(move)),"seed":"\#(seed)"}"#
                        let reply = Bridge.handle(request)
                        if let next = decodeState(reply) {
                            lines.append(record(request, reply))
                            state = next; response = reply; applied = true; break
                        }
                        // Keep a sample of refusals so error results are compared too.
                        if rejectedRecorded < 3 { lines.append(record(request, reply)); rejectedRecorded += 1 }
                    }
                    // Also record one move by someone whose turn it isn't.
                    if steps % 10 == 1, let next = awaitingSeats(response).first, let other = seatsOf(response).first(where: { $0 != next }), let move = candidates(state).first {
                        let request = #"{"op":"apply","state":\#(json(state)),"seat":"\#(other)","move":\#(json(move)),"seed":"1"}"#
                        lines.append(record(request, Bridge.handle(request)))
                    }
                    if !applied { break }
                }
                seed = driver.next() >> 11
                let rematch = #"{"op":"rematch","state":\#(json(state)),"seed":"\#(seed)"}"#
                lines.append(record(rematch, Bridge.handle(rematch)))
            }
        }
        return lines
    }

    static func candidates(_ state: GameEngine.State) -> [GameMove] {
        switch state {
        case .ticTacToe: return (0..<9).map { .ticTacToe(cell: $0) }
        case .connectFour: return ConnectFourRules.columnRange.map { .connectFour(column: $0) }
        case .checkers(let s): return CheckersRules.legalSteps(in: s).map { .checkers(.move(from: $0.from, to: $0.to)) } + [.checkers(.move(from: 0, to: 9))]
        case .chess(let s): return ChessRules.legalMoves(in: s).map { .chess(.move(from: $0.from, to: $0.to, promotion: $0.promotion)) } + [.chess(.move(from: 0, to: 63, promotion: nil))]
        case .colorMatch(let s):
            let hand = s.hands[s.currentPlayer] ?? []
            return hand.flatMap { card in CardColor.allCases.map { GameMove.colorMatch(.play(cardId: card.id, chosenColor: $0, callOne: true)) } }
                + [.colorMatch(.draw), .colorMatch(.pass), .colorMatch(.respondToDrawFour(challenge: false)), .colorMatch(.respondToDrawFour(challenge: true))]
        case .spades(let s):
            let hand = s.hands[s.currentPlayer] ?? []
            return (0...13).map { .spades(.bid(tricks: $0)) } + hand.map { .spades(.play(cardId: $0.id)) } + [.spades(.play(cardId: 51))]
        case .tonk(let s):
            let hand = s.hands[s.currentPlayer] ?? []
            return [.tonk(.drawFromStock), .tonk(.takeDiscard)] + hand.map { .tonk(.discard(cardId: $0.id)) }
        }
    }

    struct Envelope: Decodable { var state: GameEngine.State?; var awaiting: [String]? }

    static func decodeState(_ response: String) -> GameEngine.State? {
        (try? JSONDecoder().decode(Envelope.self, from: Data(response.utf8)))?.state
    }

    struct Views: Decodable { var views: [String: GameStateSnapshot]? }
    static func seatsOf(_ response: String) -> [String] {
        ((try? JSONDecoder().decode(Views.self, from: Data(response.utf8)))?.views?.keys).map { Array($0).sorted() } ?? []
    }

    static func awaitingSeats(_ response: String) -> [String] {
        (try? JSONDecoder().decode(Envelope.self, from: Data(response.utf8)))?.awaiting ?? []
    }

    static func json(_ value: some Encodable) -> String {
        String(decoding: (try? Bridge.encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    static func record(_ request: String, _ response: String) -> String {
        #"{"request":\#(request),"response":\#(response)}"#
    }
}

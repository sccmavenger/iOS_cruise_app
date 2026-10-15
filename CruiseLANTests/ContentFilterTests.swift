import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Content filter")
struct ContentFilterTests {
    let filter = ContentFilter.shared

    @Test("Bundled term list loads")
    func loads() {
        #expect(filter.patternCount > 400)
    }

    @Test("Clean kid chat is allowed", arguments: [
        "Hi! Want to play tic-tac-toe?",
        "Meet at the pool after lunch",
        "That class was fun",
        "I passed the assessment",
        "My assistant teacher is nice",
        "We saw a peacock and a cockatoo",
        "Grab a cocktail sauce for the shrimp",
        "Scunthorpe and Essex are in England",
        "The Titanic was huge",
        "Shiitake mushrooms are gross",
        "I like Charles Dickens",
        "Grapes and skyscrapers",
        "I'm an analyst at heart, I love analysis",
        "Kung fu panda is my favorite",
        "The pussycat is sleeping",
        "Let's go to the seashell shop at 3",
        "I scored 12 points",
        "Hello there",
        "This is the best day ever!!!",
        "GG, you win",
        "I'm on deck 7",
        "The pilot showed us the cockpit",
        "What time is dinner? 6:30?",
        "See you on 10/15/2026 at 6:30",
        "Scores: 12, 9, 7 and 4",
    ])
    func allowed(text: String) {
        #expect(filter.check(text) == .allowed, "\(text)")
    }

    @Test("Profanity and sexual content are blocked", arguments: [
        "what the fuck",
        "this is shit",
        "you're a bitch",
        "send nudes",
        "wanna see porn",
        "sexy",
        "let's have sex",
        "nice boobs",
        "you dick",
        "kill yourself",
        "stfu",
        "ass",
        "bullshit",
        "horny",
    ])
    func blocked(text: String) {
        #expect(filter.check(text) == .blocked(.inappropriate), "\(text)")
    }

    @Test("Common evasions are caught", arguments: [
        "FUCK",
        "fuuuuuck",
        "f u c k",
        "f.u.c.k",
        "f_u_c_k",
        "fvck",
        "phuck off",
        "$h1t",
        "sh!t",
        "b1tch",
        "p0rn",
        "s3x",
        "ｆｕｃｋ",           // full-width
        "fu\u{200B}ck",        // zero-width space
        "sеx",                 // Cyrillic е
        "pörn",                // diacritic
        "s e x y",
    ])
    func evasions(text: String) {
        #expect(!filter.check(text).isAllowed, "\(text)")
    }

    @Test("Personal information is blocked", arguments: [
        "call me 555-123-4567",
        "my number is (555) 123 4567",
        "email me kid123@example.com",
        "kid123 at gmail dot com",
        "go to www.example.com",
        "check example.com",
        "add me on snapchat",
        "my insta is cool_kid",
        "I'm in cabin 8241",
        "cabin 8 2 1 4",
        "call 555/123/4567",
        "555_123*4567",
        "stateroom #10512",
        "follow @cool_kid99",
        "discord?",
    ])
    func personalInfo(text: String) {
        #expect(filter.check(text) == .blocked(.personalInfo), "\(text)")
    }

    @Test("Nicknames: bad names are replaced for display")
    func nicknames() {
        #expect(filter.safeNickname("Captain Sam") == "Captain Sam")
        #expect(filter.safeNickname("SexyKid") == "Player")
        #expect(filter.safeNickname("f4ck") == "Player")
        #expect(filter.safeNickname("sexy123") == "Player")
        #expect(filter.safeNickname("BigButt") == "Player")
        #expect(filter.safeNickname("iPhoneKid") == "iPhoneKid")
        #expect(filter.safeNickname("Gamer2015") == "Gamer2015")
        #expect(filter.safeNickname("Assassin") == "Assassin")
        #expect(filter.checkNickname("Dickens Fan") == .allowed)
    }

    @Test("Filtering a long message is fast")
    func performance() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 22)
        let start = Date()
        for _ in 0..<10 { _ = filter.check(text) }
        #expect(Date().timeIntervalSince(start) / 10 < 0.05)
    }
}

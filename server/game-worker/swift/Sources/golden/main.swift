import CruiseGameRules
// Usage: golden <gamesPerType> <maxSteps>  → JSON lines on stdout
let arguments = CommandLine.arguments
let games = arguments.count > 1 ? Int(arguments[1]) ?? 3 : 3
let steps = arguments.count > 2 ? Int(arguments[2]) ?? 300 : 300
for line in GoldenTrace.generate(gamesPerType: games, maxSteps: steps) { print(line) }

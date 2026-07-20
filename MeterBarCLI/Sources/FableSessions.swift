import ArgumentParser
import MeterBar

struct FableSessions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fable-sessions",
        abstract: "Show Fable 5 sessions from MeterBar's persisted metadata snapshot"
    )

    @Flag(name: .shortAndLong, help: "Output the versioned JSON schema")
    var json = false

    func run() throws {
        let sessions = ClaudeFableSessionStore().load()
        if json {
            try emitJSON(FableSessionsCLIJSONResponse(sessions: sessions))
        } else {
            print(FableSessionsTextFormatter.format(sessions))
        }
    }
}

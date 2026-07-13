import AppKit

// Headless test mode: `PrivateWhisper --test-file audio.wav [--no-cleanup]`
// runs transcription (+ cleanup) on a file and prints JSON — used for
// automated pipeline tests without a microphone.
AppConfig.migrateLegacySupportDir()

if let idx = CommandLine.arguments.firstIndex(of: "--test-diff"),
   CommandLine.arguments.count > idx + 2 {
    let suggestions = CorrectionLearner.corrections(
        original: CommandLine.arguments[idx + 1], edited: CommandLine.arguments[idx + 2])
    print(suggestions.joined(separator: ", "))
    exit(0)
} else if CommandLine.arguments.contains("--test-file") {
    TestMode.run(arguments: CommandLine.arguments)
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

import Foundation
import ArgumentParser
import WaxAndWaneCore

struct CLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wax-and-wane",
        abstract: "Adjust keyboard/screen brightness based on ambient light.",
        subcommands: [Run.self, Doctor.self, PrintDefaultConfig.self],
        defaultSubcommand: Run.self
    )
}

struct PrintDefaultConfig: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "print-default-config", abstract: "Print a complete JSON config template.")
    func run() throws { print(defaultConfigJSON()) }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check helpers, platform support, and privacy prerequisites.")
    func run() throws { runDoctor() }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Start the ambient brightness loop.")

    @Option(help: "JSON config file path (CLI flags override)") var config: String? = nil
    @Option(name: .long, help: "Seconds between brightness updates") var pollInterval: Double? = nil
    @Option(name: .long, help: "Smoothing window size (number of samples)") var smoothingWindow: Int? = nil
    @Option(name: .long, help: "Minimum brightness delta to trigger an update") var changeThreshold: Float? = nil
    @Option(name: .long, help: "Brightness increase delta threshold") var riseThreshold: Float? = nil
    @Option(name: .long, help: "Brightness decrease delta threshold") var fallThreshold: Float? = nil
    @Option(name: .long, help: "Minimum seconds between backend writes") var minUpdateInterval: Double? = nil
    @Option(name: .long, help: "Ambient sample that represents darkness [0-1]") var ambientDark: Float? = nil
    @Option(name: .long, help: "Ambient sample that represents brightness [0-1]") var ambientBright: Float? = nil
    @Option(name: .long, help: "Gamma for calibrated ambient curve") var outputGamma: Float? = nil
    @Option(name: .long, help: "Keyboard brightness lower bound [0-1]") var keyboardMin: Float? = nil
    @Option(name: .long, help: "Keyboard brightness upper bound [0-1]") var keyboardMax: Float? = nil
    @Flag(name: .long, inversion: .prefixedNo, exclusivity: .chooseLast, help: "Invert keyboard mapping (bright→dark)") var invertKeyboard: Bool? = nil
    @Option(name: .long, help: "Keyboard mode: ambient auto, fixed manual, or leave to system") var keyboardControl: BrightnessControl? = nil
    @Option(name: .long, help: "Preferred keyboard backend name") var keyboardBackend: String? = nil
    @Option(name: .long, help: "Fixed keyboard brightness when --keyboard-control manual [0-1]") var manualKeyboard: Float? = nil
    @Option(name: .long, help: "Screen brightness lower bound [0-1]") var screenMin: Float? = nil
    @Option(name: .long, help: "Screen brightness upper bound [0-1]") var screenMax: Float? = nil
    @Flag(name: .long, inversion: .prefixedNo, exclusivity: .chooseLast, help: "Invert screen mapping") var invertScreen: Bool? = nil
    @Option(name: .long, help: "Screen mode: ambient auto, fixed manual, or leave to system") var screenControl: BrightnessControl? = nil
    @Option(name: .long, help: "Preferred screen backend name") var screenBackend: String? = nil
    @Option(name: .long, help: "Fixed screen brightness when --screen-control manual [0-1]") var manualScreen: Float? = nil
    @Option(name: .long, help: "Keyboard brightness restored on exit [0-1]") var defaultKeyboard: Float? = nil
    @Option(name: .long, help: "Screen brightness restored on exit [0-1]") var defaultScreen: Float? = nil
    @Flag(name: .long, inversion: .prefixedNo, exclusivity: .chooseLast, help: "Do not write brightness; print backend commands instead") var dryRun: Bool? = nil
    @Flag(name: .customLong("restore-original-brightness"), inversion: .prefixedNo, exclusivity: .chooseLast, help: "Restore original brightness observed at startup") var restoreOriginalBrightness: Bool? = nil
    @Option(name: .long, help: "Stop after this many seconds (0 = unlimited)") var maxRuntime: Double? = nil

    func buildSettings() throws -> Settings {
        var s = try config.map(loadConfig) ?? Settings()
        if let v = pollInterval { s.pollIntervalSeconds = v }
        if let v = smoothingWindow { s.smoothingWindow = v }
        if let v = changeThreshold { s.changeThreshold = v }
        if let v = riseThreshold { s.riseThreshold = v }
        if let v = fallThreshold { s.fallThreshold = v }
        if let v = minUpdateInterval { s.minUpdateIntervalSeconds = v }
        if let v = ambientDark { s.ambientDark = v }
        if let v = ambientBright { s.ambientBright = v }
        if let v = outputGamma { s.outputGamma = v }
        if let v = keyboardMin { s.keyboardMin = v }
        if let v = keyboardMax { s.keyboardMax = v }
        if let v = keyboardControl { s.keyboardControl = v }
        if let v = keyboardBackend { s.keyboardBackend = v }
        if let v = manualKeyboard { s.manualKeyboardBrightness = v }
        if let v = screenMin { s.screenMin = v }
        if let v = screenMax { s.screenMax = v }
        if let v = screenControl { s.screenControl = v }
        if let v = screenBackend { s.screenBackend = v }
        if let v = manualScreen { s.manualScreenBrightness = v }
        if let v = defaultKeyboard { s.defaultKeyboardBrightness = v }
        if let v = defaultScreen { s.defaultScreenBrightness = v }
        if let v = maxRuntime { s.maxCameraRuntimeSeconds = v }
        if let v = invertKeyboard { s.invertKeyboard = v }
        if let v = invertScreen { s.invertScreen = v }
        if let v = dryRun { s.dryRun = v }
        if let v = restoreOriginalBrightness { s.restoreOriginalBrightness = v }
        try validateSettings(s)
        return s
    }

    func run() throws {
        let settings = try buildSettings()
        try runApplication(settings: settings)
    }
}

CLI.main()

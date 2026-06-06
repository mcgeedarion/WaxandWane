import Foundation
import ArgumentParser

enum BrightnessControl: String, Codable, ExpressibleByArgument {
    case auto
    case manual
    case system
}

struct Settings: Codable {
    var pollIntervalSeconds: TimeInterval = 2.0
    var smoothingWindow: Int = 5
    var changeThreshold: Float = 0.02
    var riseThreshold: Float? = nil
    var fallThreshold: Float? = nil
    var minUpdateIntervalSeconds: TimeInterval = 0.0

    var ambientDark: Float = 0.0
    var ambientBright: Float = 1.0
    var outputGamma: Float = 1.0

    var keyboardMin: Float = 0.0
    var keyboardMax: Float = 1.0
    var invertKeyboard: Bool = false
    var keyboardControl: BrightnessControl = .auto
    var manualKeyboardBrightness: Float = 0.5
    var keyboardBackend: String? = nil

    var screenMin: Float = 0.2
    var screenMax: Float = 1.0
    var invertScreen: Bool = false
    var screenControl: BrightnessControl = .auto
    var manualScreenBrightness: Float = 0.7
    var screenBackend: String? = nil

    var defaultKeyboardBrightness: Float = 0.5
    var defaultScreenBrightness: Float = 0.7
    var restoreOriginalBrightness: Bool = true
    var dryRun: Bool = false

    var maxCameraRuntimeSeconds: TimeInterval = 3600
    var reminderIntervalSeconds: TimeInterval = 900
}

enum SettingsError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

func loadConfig(path: String) throws -> Settings {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Settings.self, from: data)
}

func defaultConfigJSON() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Settings())
    return String(decoding: data, as: UTF8.self)
}

func validateSettings(_ s: Settings) throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SettingsError.invalid(message) }
    }
    func unit(_ value: Float, _ name: String) throws {
        try check(value >= 0.0 && value <= 1.0, "\(name) must be in [0, 1]")
    }
    func nonNegative(_ value: TimeInterval, _ name: String) throws {
        try check(value >= 0.0, "\(name) must be >= 0")
    }
    func nonNegativeFloat(_ value: Float, _ name: String) throws {
        try check(value >= 0.0, "\(name) must be >= 0")
    }

    try check(s.pollIntervalSeconds > 0, "pollIntervalSeconds must be > 0")
    try check(s.smoothingWindow > 0, "smoothingWindow must be > 0")
    try nonNegativeFloat(s.changeThreshold, "changeThreshold")
    if let rise = s.riseThreshold { try nonNegativeFloat(rise, "riseThreshold") }
    if let fall = s.fallThreshold { try nonNegativeFloat(fall, "fallThreshold") }
    try nonNegative(s.minUpdateIntervalSeconds, "minUpdateIntervalSeconds")
    try unit(s.ambientDark, "ambientDark")
    try unit(s.ambientBright, "ambientBright")
    try check(s.ambientBright > s.ambientDark, "ambientBright must be greater than ambientDark")
    try check(s.outputGamma > 0, "outputGamma must be > 0")

    try unit(s.keyboardMin, "keyboardMin")
    try unit(s.keyboardMax, "keyboardMax")
    try check(s.keyboardMin <= s.keyboardMax, "keyboardMin must be <= keyboardMax")
    try unit(s.manualKeyboardBrightness, "manualKeyboardBrightness")
    try unit(s.defaultKeyboardBrightness, "defaultKeyboardBrightness")

    try unit(s.screenMin, "screenMin")
    try unit(s.screenMax, "screenMax")
    try check(s.screenMin <= s.screenMax, "screenMin must be <= screenMax")
    try unit(s.manualScreenBrightness, "manualScreenBrightness")
    try unit(s.defaultScreenBrightness, "defaultScreenBrightness")

    try nonNegative(s.maxCameraRuntimeSeconds, "maxCameraRuntimeSeconds")
    try nonNegative(s.reminderIntervalSeconds, "reminderIntervalSeconds")
}

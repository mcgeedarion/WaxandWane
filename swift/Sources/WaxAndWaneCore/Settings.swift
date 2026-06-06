import Foundation
import ArgumentParser

public enum BrightnessControl: String, Codable, ExpressibleByArgument {
    case auto
    case manual
    case system
}

public struct Settings: Codable {
    public var pollIntervalSeconds: TimeInterval = 2.0
    public var smoothingWindow: Int = 5
    public var changeThreshold: Float = 0.02
    public var riseThreshold: Float? = nil
    public var fallThreshold: Float? = nil
    public var minUpdateIntervalSeconds: TimeInterval = 0.0

    public var ambientDark: Float = 0.0
    public var ambientBright: Float = 1.0
    public var outputGamma: Float = 1.0

    public var keyboardMin: Float = 0.0
    public var keyboardMax: Float = 1.0
    public var invertKeyboard: Bool = false
    public var keyboardControl: BrightnessControl = .auto
    public var manualKeyboardBrightness: Float = 0.5
    public var keyboardBackend: String? = nil

    public var screenMin: Float = 0.2
    public var screenMax: Float = 1.0
    public var invertScreen: Bool = false
    public var screenControl: BrightnessControl = .auto
    public var manualScreenBrightness: Float = 0.7
    public var screenBackend: String? = nil

    public var defaultKeyboardBrightness: Float = 0.5
    public var defaultScreenBrightness: Float = 0.7
    public var restoreOriginalBrightness: Bool = true
    public var dryRun: Bool = false

    public var maxCameraRuntimeSeconds: TimeInterval = 3600
    public var reminderIntervalSeconds: TimeInterval = 900

    public init() {}
}

public enum SettingsError: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

public func loadConfig(path: String) throws -> Settings {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Settings.self, from: data)
}

public func defaultConfigJSON() -> String {
    """
    {
      "ambientBright" : 1,
      "ambientDark" : 0,
      "changeThreshold" : 0.02,
      "defaultKeyboardBrightness" : 0.5,
      "defaultScreenBrightness" : 0.7,
      "dryRun" : false,
      "fallThreshold" : null,
      "invertKeyboard" : false,
      "invertScreen" : false,
      "keyboardBackend" : null,
      "keyboardControl" : "auto",
      "keyboardMax" : 1,
      "keyboardMin" : 0,
      "manualKeyboardBrightness" : 0.5,
      "manualScreenBrightness" : 0.7,
      "maxCameraRuntimeSeconds" : 3600,
      "minUpdateIntervalSeconds" : 0,
      "outputGamma" : 1,
      "pollIntervalSeconds" : 2,
      "reminderIntervalSeconds" : 900,
      "restoreOriginalBrightness" : true,
      "riseThreshold" : null,
      "screenBackend" : null,
      "screenControl" : "auto",
      "screenMax" : 1,
      "screenMin" : 0.2,
      "smoothingWindow" : 5
    }
    """
}

public func validateSettings(_ s: Settings) throws {
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

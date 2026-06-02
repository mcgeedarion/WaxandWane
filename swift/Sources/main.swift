import Foundation
import AVFoundation
import CoreMedia
import UserNotifications
import CoreVideo
import IOKit
import Accelerate
import ArgumentParser

// MARK: - Settings (policy)

enum BrightnessControl: String, Codable, ExpressibleByArgument {
    case auto
    case manual
    case system
}

/// All tuneable knobs. Fields are `var` so CLI flags and JSON config can
/// override defaults before the run loop starts.
struct Settings: Codable {
    var pollIntervalSeconds: TimeInterval = 2.0
    var smoothingWindow: Int = 5
    var changeThreshold: Float = 0.02

    var keyboardMin: Float = 0.0
    var keyboardMax: Float = 1.0
    var invertKeyboard: Bool = false  // dark room → dimmer keyboard
    var keyboardControl: BrightnessControl = .auto
    var manualKeyboardBrightness: Float = 0.5

    var screenMin: Float = 0.2
    var screenMax: Float = 1.0
    var invertScreen: Bool = false    // dark room → dimmer screen
    var screenControl: BrightnessControl = .auto
    var manualScreenBrightness: Float = 0.7

    // Restore-on-exit values (single source of truth — used by restoreDefaults)
    var defaultKeyboardBrightness: Float = 0.5
    var defaultScreenBrightness: Float   = 0.7

    // Privacy / runtime guard
    var maxCameraRuntimeSeconds: TimeInterval = 3600   // 0 = unlimited
    var reminderIntervalSeconds: TimeInterval = 900    // 0 = no reminders
}

// MARK: - CLI + JSON config

/// Loads a JSON config file and returns a Settings with the decoded values.
func loadConfig(path: String) throws -> Settings {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Settings.self, from: data)
}

struct CLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ambient-backlight",
        abstract: "Adjust keyboard/screen brightness based on ambient light."
    )

    @Option(help: "JSON config file path (CLI flags override)")
    var config: String? = nil

    @Option(name: .long, help: "Seconds between brightness updates")
    var pollInterval: Double? = nil

    @Option(name: .long, help: "Smoothing window size (number of samples)")
    var smoothingWindow: Int? = nil

    @Option(name: .long, help: "Minimum brightness delta to trigger an update")
    var changeThreshold: Float? = nil

    @Option(name: .long, help: "Keyboard brightness lower bound [0-1]")
    var keyboardMin: Float? = nil

    @Option(name: .long, help: "Keyboard brightness upper bound [0-1]")
    var keyboardMax: Float? = nil

    @Flag(name: .long, inversion: .prefixedWith, help: "Invert keyboard mapping (bright→dark)")
    var invertKeyboard: Bool = false

    @Option(name: .long, help: "Keyboard mode: ambient auto, fixed manual, or leave to system")
    var keyboardControl: BrightnessControl? = nil

    @Option(name: .long, help: "Fixed keyboard brightness when --keyboard-control manual [0-1]")
    var manualKeyboard: Float? = nil

    @Option(name: .long, help: "Screen brightness lower bound [0-1]")
    var screenMin: Float? = nil

    @Option(name: .long, help: "Screen brightness upper bound [0-1]")
    var screenMax: Float? = nil

    @Flag(name: .long, inversion: .prefixedWith, help: "Invert screen mapping")
    var invertScreen: Bool = false

    @Option(name: .long, help: "Screen mode: ambient auto, fixed manual, or leave to system")
    var screenControl: BrightnessControl? = nil

    @Option(name: .long, help: "Fixed screen brightness when --screen-control manual [0-1]")
    var manualScreen: Float? = nil

    @Option(name: .long, help: "Keyboard brightness restored on exit [0-1]")
    var defaultKeyboard: Float? = nil

    @Option(name: .long, help: "Screen brightness restored on exit [0-1]")
    var defaultScreen: Float? = nil

    @Option(name: .long, help: "Stop after this many seconds (0 = unlimited)")
    var maxRuntime: Double? = nil

    func buildSettings() throws -> Settings {
        var s: Settings
        if let path = config {
            s = try loadConfig(path: path)
        } else {
            s = Settings()
        }
        // CLI overrides – only applied when explicitly provided
        if let v = pollInterval       { s.pollIntervalSeconds = v }
        if let v = smoothingWindow    { s.smoothingWindow = v }
        if let v = changeThreshold    { s.changeThreshold = v }
        if let v = keyboardMin        { s.keyboardMin = v }
        if let v = keyboardMax        { s.keyboardMax = v }
        if let v = keyboardControl    { s.keyboardControl = v }
        if let v = manualKeyboard     { s.manualKeyboardBrightness = v }
        if let v = screenMin          { s.screenMin = v }
        if let v = screenMax          { s.screenMax = v }
        if let v = screenControl      { s.screenControl = v }
        if let v = manualScreen       { s.manualScreenBrightness = v }
        if let v = defaultKeyboard    { s.defaultKeyboardBrightness = v }
        if let v = defaultScreen      { s.defaultScreenBrightness = v }
        if let v = maxRuntime         { s.maxCameraRuntimeSeconds = v }
        // Bool flags are always present; only override if they differ from defaults
        s.invertKeyboard = invertKeyboard
        s.invertScreen   = invertScreen
        return s
    }

    mutating func run() throws {
        let settings = try buildSettings()
        try mainLoop(settings: settings)
    }
}

CLI.main()

// MARK: - Notifications

func configureNotifications() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error { fputs("Notification auth error: \(error.localizedDescription)\n", stderr) }
        if !granted  { fputs("Notification access not granted; banners disabled.\n", stderr) }
    }
}

func postNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body  = body
    let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil
    )
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
}

// MARK: - Subprocess safety

let trustedWorkingDirectory = NSHomeDirectory()
let safePathEntries = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

/// Resolves `command` to an absolute path that lies within `safePathEntries`.
/// Symlinks are fully resolved so a malicious link pointing outside the
/// trusted directories cannot bypass the allowlist.
func resolveExecutable(_ command: String) -> String? {
    let fm = FileManager.default
    for base in safePathEntries {
        let candidate = URL(fileURLWithPath: base)
            .appendingPathComponent(command).path
        guard fm.isExecutableFile(atPath: candidate) else { continue }
        let real = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        let inTrusted = safePathEntries.contains { prefix in
            real == prefix || real.hasPrefix(prefix + "/")
        }
        if inTrusted {
            return real
        } else {
            fputs("Warning: ignoring unsafe symlink target for \(command): \(real)\n", stderr)
        }
    }
    return nil
}

func sanitizedEnvironment() -> [String: String] {
    var env: [String: String] = [:]
    let current = ProcessInfo.processInfo.environment
    for key in ["LANG", "LC_ALL", "LC_CTYPE", "HOME"] {
        if let v = current[key] { env[key] = v }
    }
    env["PATH"] = safePathEntries.joined(separator: ":")
    for key in ["LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "PYTHONPATH"] {
        env.removeValue(forKey: key)
    }
    return env
}

struct ProcessLauncher {
    private let cwd = URL(fileURLWithPath: trustedWorkingDirectory)
    private let env = sanitizedEnvironment()

    @discardableResult
    func run(executablePath: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL      = URL(fileURLWithPath: executablePath)
        process.arguments          = arguments
        process.currentDirectoryURL = cwd
        process.environment        = env
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            fputs("Warning: \(executablePath) \(arguments.joined(separator: " ")): "
                  + "\(error.localizedDescription)\n", stderr)
            return false
        }
    }
}

let launcher = ProcessLauncher()

// MARK: - Unified brightness backend

enum BackendKind { case keyboard, screen }

struct BrightnessBackend {
    let kind: BackendKind
    let name: String
    let executablePath: String
    let commandBuilder: (Float) -> [String]
    let outMin: Float
    let outMax: Float

    func clamped(_ value: Float) -> Float {
        min(max(value, outMin), outMax)
    }

    func set(_ value: Float) {
        let v = clamped(value)
        let ok = launcher.run(executablePath: executablePath,
                               arguments: commandBuilder(v))
        if !ok {
            fputs("Warning: failed to set \(kind) brightness via \(name)\n", stderr)
        }
    }
}

func detectBackend(kind: BackendKind) -> BrightnessBackend? {
    let candidates: [(name: String, builder: (Float) -> [String], min: Float, max: Float)]
    switch kind {
    case .keyboard:
        candidates = [
            ("kbrightness",       { v in [String(format: "%.3f", v)] },          0.0, 1.0),
            ("mac-brightnessctl", { v in [String(Int(v * 100))] },               0.0, 1.0),
        ]
    case .screen:
        candidates = [
            ("brightness", { v in ["-l", String(format: "%.3f", v)] },           0.0, 1.0),
            ("ddcctl",     { v in ["-b", String(Int(v * 100))] },                0.0, 1.0),
        ]
    }

    for c in candidates {
        if let path = resolveExecutable(c.name) {
            print("Using \(kind) backend: \(c.name) (\(path))")
            return BrightnessBackend(
                kind: kind, name: c.name, executablePath: path,
                commandBuilder: c.builder, outMin: c.min, outMax: c.max
            )
        }
    }
    fputs("Warning: no \(kind) backend found. \(kind) control disabled.\n", stderr)
    return nil
}

// MARK: - Pure control policy

func mapAmbient(_ ambient: Float, minValue: Float, maxValue: Float, invert: Bool) -> Float {
    invert ? maxValue - ambient * (maxValue - minValue)
           : minValue + ambient * (maxValue - minValue)
}

// Ring buffer for O(1) append + O(n) mean without array shifting.
struct RingBuffer {
    private var buf: [Float]
    private var index = 0
    private var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buf = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ value: Float) {
        buf[index] = value
        index = (index + 1) % capacity
        if count < capacity { count += 1 }
    }

    var mean: Float {
        guard count > 0 else { return 0 }
        return buf[0..<count].reduce(0, +) / Float(count)
    }

    var isEmpty: Bool { count == 0 }
}

func targetForControl(
    control: BrightnessControl,
    smoothedAmbient: Float,
    lastValue: Float,
    minValue: Float,
    maxValue: Float,
    invert: Bool,
    manualValue: Float,
    changeThreshold: Float
) -> Float? {
    let target: Float
    switch control {
    case .system:
        return nil
    case .manual:
        target = manualValue
    case .auto:
        target = mapAmbient(smoothedAmbient, minValue: minValue, maxValue: maxValue, invert: invert)
    }
    return abs(target - lastValue) > changeThreshold ? target : nil
}

/// Pure – no I/O. Returns nil for each target when change is below threshold
/// or that channel is left to system control.
func computeTargets(
    history: inout RingBuffer,
    ambientNow: Float,
    lastKeyboard: Float,
    lastScreen: Float,
    s: Settings
) -> (keyboard: Float?, screen: Float?) {
    history.append(ambientNow)
    let smoothed = history.mean

    return (
        targetForControl(
            control: s.keyboardControl,
            smoothedAmbient: smoothed,
            lastValue: lastKeyboard,
            minValue: s.keyboardMin,
            maxValue: s.keyboardMax,
            invert: s.invertKeyboard,
            manualValue: s.manualKeyboardBrightness,
            changeThreshold: s.changeThreshold
        ),
        targetForControl(
            control: s.screenControl,
            smoothedAmbient: smoothed,
            lastValue: lastScreen,
            minValue: s.screenMin,
            maxValue: s.screenMax,
            invert: s.invertScreen,
            manualValue: s.manualScreenBrightness,
            changeThreshold: s.changeThreshold
        )
    )
}

// MARK: - Runtime guard

/// Called exclusively from the main thread. Thread-safety note: `maybeRemind`
/// writes `lastReminder` only from the main run loop; `BrightnessSampler`
/// callbacks run on a separate DispatchQueue and never touch RuntimeGuard.
final class RuntimeGuard {
    private let maxRuntime: TimeInterval
    private let reminderInterval: TimeInterval
    private let start = Date()
    private var lastReminder = Date()

    init(s: Settings) {
        maxRuntime       = s.maxCameraRuntimeSeconds
        reminderInterval = s.reminderIntervalSeconds
    }

    var shouldExit: Bool {
        maxRuntime > 0 && Date().timeIntervalSince(start) >= maxRuntime
    }

    func maybeRemind() {
        guard reminderInterval > 0,
              Date().timeIntervalSince(lastReminder) >= reminderInterval
        else { return }
        postNotification(
            title: "AutoKeyboardDim",
            body: "Camera is active. Press Ctrl+C to stop."
        )
        lastReminder = Date()
    }
}

// MARK: - Webcam sampling

final class BrightnessSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue   = DispatchQueue(label: "com.ambientbacklight.camera", qos: .utility)
    private var _brightness: Float = 0.5
    private let lock = NSLock()

    var currentBrightness: Float {
        lock.lock(); defer { lock.unlock() }
        return _brightness
    }

    func start() throws {
        session.beginConfiguration()
        session.sessionPreset = .low

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .unspecified
        ) else {
            throw NSError(domain: "AmbientBacklight", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "AmbientBacklight", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            throw NSError(domain: "AmbientBacklight", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)
        session.commitConfiguration()

        print("Warming up camera auto-exposure (3 s)…")
        session.startRunning()
        // Note: this blocks the calling (main) thread during startup only,
        // before the run loop begins. Acceptable for a CLI tool.
        Thread.sleep(forTimeInterval: 3.0)
        print("Ready.\n")
    }

    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let count  = height * stride

        var floatBuf = [Float](repeating: 0, count: count)
        vDSP_vfltu8(lumaBase.assumingMemoryBound(to: UInt8.self), 1, &floatBuf, 1, vDSP_Length(count))
        var mean: Float = 0
        vDSP_meanv(floatBuf, 1, &mean, vDSP_Length(count))

        lock.lock()
        _brightness = mean / 255.0
        lock.unlock()
    }
}

// MARK: - Main loop (called by CLI.run)

func mainLoop(settings: Settings) throws {
    configureNotifications()

    let keyboardEnabled = settings.keyboardControl != .system
    let screenEnabled = settings.screenControl != .system
    let keyboardBackend = keyboardEnabled ? detectBackend(kind: .keyboard) : nil
    let screenBackend = screenEnabled ? detectBackend(kind: .screen) : nil

    if !keyboardEnabled && !screenEnabled {
        fputs("Error: keyboard and screen are both set to system control; nothing to adjust.\n", stderr)
        exit(1)
    }

    if (keyboardEnabled && keyboardBackend == nil) && (screenEnabled && screenBackend == nil) {
        fputs("Error: no enabled output backends available. Install a backend or set that channel to system control.\n", stderr)
        exit(1)
    }

    func restoreDefaults() {
        if settings.keyboardControl != .system { keyboardBackend?.set(settings.defaultKeyboardBrightness) }
        if settings.screenControl != .system { screenBackend?.set(settings.defaultScreenBrightness) }
    }

    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { granted in
        if !granted {
            fputs("Camera access denied.\nSystem Settings → Privacy & Security → Camera\n", stderr)
        }
        semaphore.signal()
    }
    semaphore.wait()

    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { exit(1) }

    let sampler = BrightnessSampler()
    do {
        try sampler.start()
    } catch {
        fputs("Camera error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    postNotification(
        title: "AutoKeyboardDim",
        body: "Camera is now active to adjust keyboard and screen brightness."
    )

    var history = RingBuffer(capacity: settings.smoothingWindow)
    var lastKeyboard: Float = -1.0
    var lastScreen:   Float = -1.0
    let runtimeGuard = RuntimeGuard(s: settings)

    let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    sigSrc.setEventHandler {
        print("\nRestoring defaults…")
        restoreDefaults()
        sampler.stop()
        exit(0)
    }
    sigSrc.resume()

    print("Ambient backlight running (camera active). Press Ctrl+C to stop.\n")

    while true {
        if runtimeGuard.shouldExit {
            print("Max runtime reached. Stopping.")
            restoreDefaults()
            sampler.stop()
            break
        }
        runtimeGuard.maybeRemind()

        let ambientNow = sampler.currentBrightness
        let (newKbd, newScr) = computeTargets(
            history: &history,
            ambientNow: ambientNow,
            lastKeyboard: lastKeyboard,
            lastScreen: lastScreen,
            s: settings
        )

        if let v = newKbd {
            keyboardBackend?.set(v)
            lastKeyboard = v
        }
        if let v = newScr {
            screenBackend?.set(v)
            lastScreen = v
        }

        let smoothed = history.isEmpty ? ambientNow : history.mean
        let keyboardStatus = settings.keyboardControl == .system
            ? "system"
            : String(format: "%.0f%%", lastKeyboard * 100)
        let screenStatus = settings.screenControl == .system
            ? "system"
            : String(format: "%.0f%%", lastScreen * 100)
        print(String(format: "Ambient: %.3f → Keyboard: %@ | Screen: %@",
                     smoothed, keyboardStatus, screenStatus))

        Thread.sleep(forTimeInterval: settings.pollIntervalSeconds)
    }
}

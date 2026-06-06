import Foundation

public let trustedWorkingDirectory = NSHomeDirectory()
public let safePathEntries = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

public func resolveExecutable(_ command: String) -> String? {
    let fm = FileManager.default
    for base in safePathEntries {
        let candidate = URL(fileURLWithPath: base).appendingPathComponent(command).path
        guard fm.isExecutableFile(atPath: candidate) else { continue }
        let real = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        let inTrusted = safePathEntries.contains { prefix in real == prefix || real.hasPrefix(prefix + "/") }
        if inTrusted { return real }
        fputs("Warning: ignoring unsafe symlink target for \(command): \(real)\n", stderr)
    }
    return nil
}

public func sanitizedEnvironment() -> [String: String] {
    var env: [String: String] = [:]
    let current = ProcessInfo.processInfo.environment
    for key in ["LANG", "LC_ALL", "LC_CTYPE", "HOME"] {
        if let v = current[key] { env[key] = v }
    }
    env["PATH"] = safePathEntries.joined(separator: ":")
    return env
}

public struct ProcessResult {
    public let ok: Bool
    public let stdout: String
    public let stderr: String
}

public struct ProcessLauncher {
    private let cwd = URL(fileURLWithPath: trustedWorkingDirectory)
    private let env = sanitizedEnvironment()

    public init() {}

    public func run(executablePath: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ProcessResult(ok: process.terminationStatus == 0, stdout: stdout, stderr: stderr)
        } catch {
            return ProcessResult(ok: false, stdout: "", stderr: error.localizedDescription)
        }
    }
}

public let launcher = ProcessLauncher()

public enum BackendKind: String { case keyboard, screen }

public struct BackendCandidate {
    public let name: String
    public let builder: (Float) -> [String]
    public let reader: (() -> [String])?
    public let parser: ((String) -> Float?)?
    public let min: Float
    public let max: Float

    public init(name: String, builder: @escaping (Float) -> [String], reader: (() -> [String])?, parser: ((String) -> Float?)?, min: Float, max: Float) {
        self.name = name
        self.builder = builder
        self.reader = reader
        self.parser = parser
        self.min = min
        self.max = max
    }
}

public func keyboardCandidates() -> [BackendCandidate] {
    [
        BackendCandidate(name: "kbrightness", builder: { [String(format: "%.3f", $0)] }, reader: nil, parser: nil, min: 0, max: 1),
        BackendCandidate(name: "mac-brightnessctl", builder: { [String(Int($0 * 100))] }, reader: nil, parser: nil, min: 0, max: 1),
    ]
}

public func screenCandidates() -> [BackendCandidate] {
    [
        BackendCandidate(name: "brightness", builder: { ["-l", String(format: "%.3f", $0)] }, reader: { ["-l"] }, parser: parseFirstUnitFloat, min: 0, max: 1),
        BackendCandidate(name: "ddcctl", builder: { ["-b", String(Int($0 * 100))] }, reader: nil, parser: nil, min: 0, max: 1),
    ]
}

public func parseFirstUnitFloat(_ text: String) -> Float? {
    let pattern = #"(?:0(?:\.\d+)?|1(?:\.0+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text) else { return nil }
    return Float(text[range])
}

public struct BrightnessBackend {
    public let kind: BackendKind
    public let name: String
    public let executablePath: String
    public let commandBuilder: (Float) -> [String]
    public let readBuilder: (() -> [String])?
    public let readParser: ((String) -> Float?)?
    public let outMin: Float
    public let outMax: Float
    public let dryRun: Bool

    public func clamped(_ value: Float) -> Float { min(max(value, outMin), outMax) }

    public func set(_ value: Float) {
        let v = clamped(value)
        let args = commandBuilder(v)
        if dryRun {
            print("[dry-run] \(executablePath) \(args.joined(separator: " "))")
            return
        }
        let result = launcher.run(executablePath: executablePath, arguments: args)
        if !result.ok {
            fputs("Warning: failed to set \(kind.rawValue) brightness via \(name): \(result.stderr)\n", stderr)
        }
    }

    public func currentBrightness() -> Float? {
        guard let readBuilder, let readParser else { return nil }
        let result = launcher.run(executablePath: executablePath, arguments: readBuilder())
        guard result.ok else { return nil }
        return readParser(result.stdout)
    }
}

public func detectBackend(kind: BackendKind, preferredName: String? = nil, dryRun: Bool = false) -> BrightnessBackend? {
    let candidates = kind == .keyboard ? keyboardCandidates() : screenCandidates()
    let filtered = preferredName.map { wanted in candidates.filter { $0.name == wanted } } ?? candidates
    if filtered.isEmpty {
        fputs("Warning: unknown \(kind.rawValue) backend '\(preferredName ?? "")'.\n", stderr)
        return nil
    }

    for c in filtered {
        if let path = resolveExecutable(c.name) {
            print("Using \(kind.rawValue) backend: \(c.name) (\(path))")
            return BrightnessBackend(kind: kind, name: c.name, executablePath: path, commandBuilder: c.builder, readBuilder: c.reader, readParser: c.parser, outMin: c.min, outMax: c.max, dryRun: dryRun)
        }
    }
    fputs("Warning: no \(kind.rawValue) backend found. \(kind.rawValue.capitalized) control disabled.\n", stderr)
    return nil
}

public func backendDoctorLine(_ candidate: BackendCandidate) -> String {
    if let path = resolveExecutable(candidate.name) { return "✓ \(candidate.name): \(path)" }
    return "✗ \(candidate.name): not found in \(safePathEntries.joined(separator: ", "))"
}

import Foundation

let trustedWorkingDirectory = NSHomeDirectory()
let safePathEntries = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

func resolveExecutable(_ command: String) -> String? {
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

func sanitizedEnvironment() -> [String: String] {
    var env: [String: String] = [:]
    let current = ProcessInfo.processInfo.environment
    for key in ["LANG", "LC_ALL", "LC_CTYPE", "HOME"] {
        if let v = current[key] { env[key] = v }
    }
    env["PATH"] = safePathEntries.joined(separator: ":")
    return env
}

struct ProcessResult {
    let ok: Bool
    let stdout: String
    let stderr: String
}

struct ProcessLauncher {
    private let cwd = URL(fileURLWithPath: trustedWorkingDirectory)
    private let env = sanitizedEnvironment()

    func run(executablePath: String, arguments: [String]) -> ProcessResult {
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

let launcher = ProcessLauncher()

enum BackendKind: String { case keyboard, screen }

struct BackendCandidate {
    let name: String
    let builder: (Float) -> [String]
    let reader: (() -> [String])?
    let parser: ((String) -> Float?)?
    let min: Float
    let max: Float
}

func keyboardCandidates() -> [BackendCandidate] {
    [
        BackendCandidate(name: "kbrightness", builder: { [String(format: "%.3f", $0)] }, reader: nil, parser: nil, min: 0, max: 1),
        BackendCandidate(name: "mac-brightnessctl", builder: { [String(Int($0 * 100))] }, reader: nil, parser: nil, min: 0, max: 1),
    ]
}

func screenCandidates() -> [BackendCandidate] {
    [
        BackendCandidate(name: "brightness", builder: { ["-l", String(format: "%.3f", $0)] }, reader: { ["-l"] }, parser: parseFirstUnitFloat, min: 0, max: 1),
        BackendCandidate(name: "ddcctl", builder: { ["-b", String(Int($0 * 100))] }, reader: nil, parser: nil, min: 0, max: 1),
    ]
}

func parseFirstUnitFloat(_ text: String) -> Float? {
    let pattern = #"(?:0(?:\.\d+)?|1(?:\.0+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text) else { return nil }
    return Float(text[range])
}

struct BrightnessBackend {
    let kind: BackendKind
    let name: String
    let executablePath: String
    let commandBuilder: (Float) -> [String]
    let readBuilder: (() -> [String])?
    let readParser: ((String) -> Float?)?
    let outMin: Float
    let outMax: Float
    let dryRun: Bool

    func clamped(_ value: Float) -> Float { min(max(value, outMin), outMax) }

    func set(_ value: Float) {
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

    func currentBrightness() -> Float? {
        guard let readBuilder, let readParser else { return nil }
        let result = launcher.run(executablePath: executablePath, arguments: readBuilder())
        guard result.ok else { return nil }
        return readParser(result.stdout)
    }
}

func detectBackend(kind: BackendKind, preferredName: String? = nil, dryRun: Bool = false) -> BrightnessBackend? {
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

func backendDoctorLine(_ candidate: BackendCandidate) -> String {
    if let path = resolveExecutable(candidate.name) { return "✓ \(candidate.name): \(path)" }
    return "✗ \(candidate.name): not found in \(safePathEntries.joined(separator: ", "))"
}

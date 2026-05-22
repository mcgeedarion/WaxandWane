import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import IOKit
import IOKit.hid
import Accelerate

// MARK: - Configuration

let pollIntervalSeconds: Double = 2.0
let smoothingWindow      = 5
let brightnessMin: Float = 0.0
let brightnessMax: Float = 1.0
let invert               = true   // true = dark room → full backlight
let changeThreshold: Float = 0.02 // only write to IOKit if delta > 2%

// MARK: - IOKit Keyboard Backlight

private var ioService: io_service_t = IO_OBJECT_NULL
private var ioConnect: io_connect_t = IO_OBJECT_NULL

private let kSetLEDBrightness: UInt32 = 1
private let kGetLEDBrightness: UInt32 = 2

func openIOKitConnection() -> Bool {
    ioService = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleLMUController")
    )
    guard ioService != IO_OBJECT_NULL else {
        fputs("Error: AppleLMUController not found. Is this a Mac with a backlit keyboard?\n", stderr)
        return false
    }
    let kr = IOServiceOpen(ioService, mach_task_self_, 0, &ioConnect)
    guard kr == KERN_SUCCESS else {
        fputs("Error: IOServiceOpen failed (\(kr))\n", stderr)
        return false
    }
    return true
}

func closeIOKitConnection() {
    if ioConnect != IO_OBJECT_NULL { IOServiceClose(ioConnect) }
    if ioService != IO_OBJECT_NULL { IOObjectRelease(ioService) }
}

/// Sets keyboard brightness. value must be in [0.0, 1.0].
/// Internally the IOKit range is 0x000 – 0xfff (12-bit).
func setKeyboardBrightness(_ value: Float) {
    let clamped = min(max(value, brightnessMin), brightnessMax)
    let raw     = UInt64(clamped * 0xfff)
    var input   = raw
    var output  = UInt64(0)
    var outputCount: UInt32 = 1

    let kr = IOConnectCallScalarMethod(
        ioConnect,
        kSetLEDBrightness,
        &input,  1,
        &output, &outputCount
    )
    if kr != KERN_SUCCESS {
        fputs("Warning: Failed to set brightness (\(kr))\n", stderr)
    }
}

// MARK: - Webcam Brightness Sampling

final class BrightnessSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session  = AVCaptureSession()
    private let queue    = DispatchQueue(label: "com.ambientbacklight.camera", qos: .utility)
    private var latestBrightness: Float = 0.5
    private let lock = NSLock()

    var currentBrightness: Float {
        lock.lock(); defer { lock.unlock() }
        return latestBrightness
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

        let width  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let count  = height * stride

        var floatBuf = [Float](repeating: 0, count: count)
        vDSP_vfltu8(lumaBase.assumingMemoryBound(to: UInt8.self), 1, &floatBuf, 1, vDSP_Length(count))

        var mean: Float = 0
        vDSP_meanv(floatBuf, 1, &mean, vDSP_Length(count))

        let normalized = mean / 255.0

        lock.lock()
        latestBrightness = normalized
        lock.unlock()
    }
}

// MARK: - Ambient → Keyboard mapping

func ambientToKeyboard(_ ambient: Float) -> Float {
    if invert {
        return brightnessMax - ambient * (brightnessMax - brightnessMin)
    }
    return brightnessMin + ambient * (brightnessMax - brightnessMin)
}

// MARK: - Entry Point

let semaphore = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { granted in
    if !granted {
        fputs("Camera access denied. Grant access in:\nSystem Settings → Privacy & Security → Camera\n", stderr)
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()

guard openIOKitConnection() else { exit(1) }

let sampler = BrightnessSampler()
do {
    try sampler.start()
} catch {
    fputs("Camera error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

var history = [Float]()
var lastSetBrightness: Float = -1.0

let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigSrc.setEventHandler {
    print("\nRestoring keyboard brightness to 50%…")
    setKeyboardBrightness(0.5)
    sampler.stop()
    closeIOKitConnection()
    exit(0)
}
sigSrc.resume()

print("Ambient backlight running. Press Ctrl+C to stop.\n")

while true {
    let ambient = sampler.currentBrightness
    history.append(ambient)
    if history.count > smoothingWindow { history.removeFirst() }

    let smoothed = history.reduce(0, +) / Float(history.count)
    let target   = ambientToKeyboard(smoothed)

    if abs(target - lastSetBrightness) > changeThreshold {
        setKeyboardBrightness(target)
        lastSetBrightness = target
        let pct = Int(target * 100)
        print(String(format: "Ambient: %.3f → Keyboard: %d%%", smoothed, pct))
    }

    Thread.sleep(forTimeInterval: pollIntervalSeconds)
}

import XCTest

// ---------------------------------------------------------------------------
// Inline the pure functions under test so the test target compiles standalone
// without depending on the executable target (which has top-level expressions).
// ---------------------------------------------------------------------------

enum BrightnessControl {
    case auto
    case manual
    case system
}

struct Settings {
    var keyboardMin: Float = 0.0
    var keyboardMax: Float = 1.0
    var invertKeyboard: Bool = false  // dark room → dimmer keyboard (default)
    var keyboardControl: BrightnessControl = .auto
    var manualKeyboardBrightness: Float = 0.5
    var screenMin: Float = 0.2
    var screenMax: Float = 1.0
    var invertScreen: Bool = false
    var screenControl: BrightnessControl = .auto
    var manualScreenBrightness: Float = 0.7
    var changeThreshold: Float = 0.02
    var smoothingWindow: Int = 5
}

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

func mapAmbient(_ ambient: Float, minValue: Float, maxValue: Float, invert: Bool) -> Float {
    invert ? maxValue - ambient * (maxValue - minValue)
           : minValue + ambient * (maxValue - minValue)
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
        targetForControl(control: s.keyboardControl, smoothedAmbient: smoothed,
                         lastValue: lastKeyboard, minValue: s.keyboardMin,
                         maxValue: s.keyboardMax, invert: s.invertKeyboard,
                         manualValue: s.manualKeyboardBrightness, changeThreshold: s.changeThreshold),
        targetForControl(control: s.screenControl, smoothedAmbient: smoothed,
                         lastValue: lastScreen, minValue: s.screenMin,
                         maxValue: s.screenMax, invert: s.invertScreen,
                         manualValue: s.manualScreenBrightness, changeThreshold: s.changeThreshold)
    )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

final class MapAmbientTests: XCTestCase {
    func testNoInvertMin() {
        XCTAssertEqual(mapAmbient(0.0, minValue: 0.2, maxValue: 1.0, invert: false), 0.2, accuracy: 1e-5)
    }
    func testNoInvertMax() {
        XCTAssertEqual(mapAmbient(1.0, minValue: 0.2, maxValue: 1.0, invert: false), 1.0, accuracy: 1e-5)
    }
    func testNoInvertMid() {
        XCTAssertEqual(mapAmbient(0.5, minValue: 0.0, maxValue: 1.0, invert: false), 0.5, accuracy: 1e-5)
    }
    func testInvertMin() {
        // invert=true, ambient=0 → maxValue (inverted mapping, not the default behaviour)
        XCTAssertEqual(mapAmbient(0.0, minValue: 0.0, maxValue: 1.0, invert: true), 1.0, accuracy: 1e-5)
    }
    func testInvertMax() {
        XCTAssertEqual(mapAmbient(1.0, minValue: 0.0, maxValue: 1.0, invert: true), 0.0, accuracy: 1e-5)
    }
    func testInvertMid() {
        XCTAssertEqual(mapAmbient(0.5, minValue: 0.0, maxValue: 1.0, invert: true), 0.5, accuracy: 1e-5)
    }
}

final class ComputeTargetsTests: XCTestCase {
    func makeHistory(capacity: Int = 5) -> RingBuffer { RingBuffer(capacity: capacity) }

    func testFirstSampleAlwaysTriggers() {
        var h = makeHistory()
        let s = Settings()
        let (kbd, scr) = computeTargets(history: &h, ambientNow: 0.5,
                                        lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        XCTAssertNotNil(kbd)
        XCTAssertNotNil(scr)
    }

    func testNoDeltaBelowThreshold() {
        var h = makeHistory()
        var s = Settings()
        s.changeThreshold = 0.05
        _ = computeTargets(history: &h, ambientNow: 0.5,
                           lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        let (kbd, _) = computeTargets(history: &h, ambientNow: 0.5,
                                      lastKeyboard: 0.5, lastScreen: 0.3, s: s)
        XCTAssertNil(kbd)
    }

    func testChangeAboveThresholdTriggers() {
        var h = makeHistory()
        let s = Settings(changeThreshold: 0.02)
        _ = computeTargets(history: &h, ambientNow: 0.1,
                           lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        let (kbd, scr) = computeTargets(history: &h, ambientNow: 0.9,
                                        lastKeyboard: 0.1, lastScreen: 0.1, s: s)
        XCTAssertNotNil(kbd)
        XCTAssertNotNil(scr)
    }

    func testSmoothingDampsSpike() {
        var h = makeHistory(capacity: 5)
        var s = Settings()
        s.smoothingWindow = 5
        s.invertKeyboard = false
        s.changeThreshold = 0.02
        for _ in 0..<5 {
            _ = computeTargets(history: &h, ambientNow: 0.5,
                               lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        }
        // Spike to 1.0; smoothed = (4*0.5 + 1.0)/5 = 0.6
        let (kbd, _) = computeTargets(history: &h, ambientNow: 1.0,
                                      lastKeyboard: 0.5, lastScreen: 0.5, s: s)
        if let kbd = kbd {
            XCTAssertLessThan(abs(kbd - 0.5), 0.2, "Spike should be damped by smoothing")
        }
    }

    func testKeyboardDarkRoomDim() {
        // invertKeyboard=false (default): dark room (ambient=0) → keyboardMin (0.0)
        var h = makeHistory()
        var s = Settings()
        s.invertKeyboard = false
        s.keyboardMin = 0.0
        s.keyboardMax = 1.0
        s.changeThreshold = 0.0
        let (kbd, _) = computeTargets(history: &h, ambientNow: 0.0,
                                      lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        XCTAssertEqual(kbd ?? -1, 0.0, accuracy: 1e-5)
    }

    func testKeyboardBrightRoomBright() {
        // invertKeyboard=false (default): bright room (ambient=1) → keyboardMax (1.0)
        var h = makeHistory()
        var s = Settings()
        s.invertKeyboard = false
        s.keyboardMin = 0.0
        s.keyboardMax = 1.0
        s.changeThreshold = 0.0
        let (kbd, _) = computeTargets(history: &h, ambientNow: 1.0,
                                      lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        XCTAssertEqual(kbd ?? -1, 1.0, accuracy: 1e-5)
    }

    func testScreenNoInvertBrightRoom() {
        var h = makeHistory()
        var s = Settings()
        s.invertScreen = false
        s.screenMin = 0.2
        s.screenMax = 1.0
        s.changeThreshold = 0.0
        let (_, scr) = computeTargets(history: &h, ambientNow: 1.0,
                                      lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        XCTAssertEqual(scr ?? -1, 1.0, accuracy: 1e-5)
    }


    func testManualKeyboardDoesNotAffectScreen() {
        var h = makeHistory()
        var s = Settings()
        s.keyboardControl = .manual
        s.manualKeyboardBrightness = 0.25
        s.screenControl = .system
        s.changeThreshold = 0.0
        let (kbd, scr) = computeTargets(history: &h, ambientNow: 1.0,
                                        lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        XCTAssertEqual(kbd ?? -1, 0.25, accuracy: 1e-5)
        XCTAssertNil(scr)
    }

    func testManualScreenDoesNotAffectKeyboard() {
        var h = makeHistory()
        var s = Settings()
        s.keyboardControl = .system
        s.screenControl = .manual
        s.manualScreenBrightness = 0.8
        s.changeThreshold = 0.0
        let (kbd, scr) = computeTargets(history: &h, ambientNow: 0.0,
                                        lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        XCTAssertNil(kbd)
        XCTAssertEqual(scr ?? -1, 0.8, accuracy: 1e-5)
    }

    func testRingBufferFill() {
        var h = makeHistory(capacity: 3)
        let s = Settings()
        _ = computeTargets(history: &h, ambientNow: 0.3, lastKeyboard: -1, lastScreen: -1, s: s)
        _ = computeTargets(history: &h, ambientNow: 0.6, lastKeyboard: 0, lastScreen: 0, s: s)
        XCTAssertEqual(h.mean, 0.45, accuracy: 1e-5)
    }
}

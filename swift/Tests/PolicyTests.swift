import XCTest

// ---------------------------------------------------------------------------
// Inline the pure functions under test so the test target compiles standalone
// without depending on the executable target (which has top-level expressions).
// ---------------------------------------------------------------------------

struct Settings {
    var keyboardMin: Float = 0.0
    var keyboardMax: Float = 1.0
    var invertKeyboard: Bool = true
    var screenMin: Float = 0.2
    var screenMax: Float = 1.0
    var invertScreen: Bool = false
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

func computeTargets(
    history: inout RingBuffer,
    ambientNow: Float,
    lastKeyboard: Float,
    lastScreen: Float,
    s: Settings
) -> (keyboard: Float?, screen: Float?) {
    history.append(ambientNow)
    let smoothed = history.mean
    let kbd = mapAmbient(smoothed, minValue: s.keyboardMin, maxValue: s.keyboardMax, invert: s.invertKeyboard)
    let scr = mapAmbient(smoothed, minValue: s.screenMin,   maxValue: s.screenMax,   invert: s.invertScreen)
    return (
        abs(kbd - lastKeyboard) > s.changeThreshold ? kbd : nil,
        abs(scr - lastScreen)   > s.changeThreshold ? scr : nil
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
        // dark room (ambient=0) → max keyboard brightness
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
        // Prime
        _ = computeTargets(history: &h, ambientNow: 0.5,
                           lastKeyboard: -1.0, lastScreen: -1.0, s: s)
        let (kbd, _) = computeTargets(history: &h, ambientNow: 0.5,
                                      lastKeyboard: 0.5, lastScreen: 0.3, s: s)
        XCTAssertNil(kbd)
    }

    func testChangAboveThresholdTriggers() {
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
        // Fill with 0.5
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

    func testKeyboardInvertDarkRoom() {
        var h = makeHistory()
        var s = Settings()
        s.invertKeyboard = true
        s.keyboardMin = 0.0
        s.keyboardMax = 1.0
        s.changeThreshold = 0.0
        let (kbd, _) = computeTargets(history: &h, ambientNow: 0.0,
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

    func testRingBufferFill() {
        var h = makeHistory(capacity: 3)
        let s = Settings()
        _ = computeTargets(history: &h, ambientNow: 0.3, lastKeyboard: -1, lastScreen: -1, s: s)
        _ = computeTargets(history: &h, ambientNow: 0.6, lastKeyboard: 0, lastScreen: 0, s: s)
        // count tracked internally; mean should be (0.3+0.6)/2 = 0.45
        XCTAssertEqual(h.mean, 0.45, accuracy: 1e-5)
    }
}

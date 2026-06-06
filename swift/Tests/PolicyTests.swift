import XCTest
@testable import WaxAndWaneCore

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
        let (kbd, _) = computeTargets(history: &h, ambientNow: 1.0,
                                      lastKeyboard: 0.5, lastScreen: 0.5, s: s)
        if let kbd = kbd {
            XCTAssertLessThan(abs(kbd - 0.5), 0.2, "Spike should be damped by smoothing")
        }
    }

    func testKeyboardDarkRoomDim() {
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


final class CalibrationTests: XCTestCase {
    func testCalibrationGammaChangesTarget() {
        XCTAssertEqual(normalizeAmbient(0.5, dark: 0.2, bright: 0.8, gamma: 2.0), 0.25, accuracy: 1e-5)
    }

    func testCalibrationClampsDarkAndBright() {
        XCTAssertEqual(normalizeAmbient(0.0, dark: 0.2, bright: 0.8, gamma: 1.0), 0.0, accuracy: 1e-5)
        XCTAssertEqual(normalizeAmbient(1.0, dark: 0.2, bright: 0.8, gamma: 1.0), 1.0, accuracy: 1e-5)
    }
}

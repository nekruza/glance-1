import CoreGraphics
import XCTest
@testable import Glance

/// FR7 regression: on macOS 15+, `CGPreflightScreenCaptureAccess` always
/// reports false for builds without a trusted Developer ID signature (our
/// self-signed dev cert), even when Screen Recording is granted. The truthful
/// signal is a successful ScreenCaptureKit probe, which must override a
/// false preflight — otherwise every ask shows the permission popup.
final class ScreenCapturePermissionTests: XCTestCase {

    override func tearDown() {
        ScreenCaptureService.preflight = { CGPreflightScreenCaptureAccess() }
        ScreenCaptureService.probedGranted = false
        super.tearDown()
    }

    func testPreflightAloneGrantsPermission() {
        ScreenCaptureService.preflight = { true }
        ScreenCaptureService.probedGranted = false
        XCTAssertTrue(ScreenCaptureService.hasPermission)
    }

    func testSuccessfulProbeOverridesFalsePreflight() {
        ScreenCaptureService.preflight = { false }
        ScreenCaptureService.probedGranted = true
        XCTAssertTrue(ScreenCaptureService.hasPermission)
    }

    func testDeniedWhenPreflightFalseAndNoProbeSuccess() {
        ScreenCaptureService.preflight = { false }
        ScreenCaptureService.probedGranted = false
        XCTAssertFalse(ScreenCaptureService.hasPermission)
    }

    /// FR7/FR8 regression: the pre-overlay grab must give up *before* it can
    /// reach ScreenCaptureKit when permission is missing. An unauthorized
    /// SCShareableContent call raises the system Screen Recording prompt, so
    /// probing here made the prompt reappear on every single overlay open.
    func testOpportunisticCaptureSkipsScreenCaptureKitWhenDenied() async {
        ScreenCaptureService.preflight = { false }
        ScreenCaptureService.probedGranted = false
        let shot = await ScreenCaptureService.captureActiveDisplayIfPermitted()
        XCTAssertNil(shot)
        // Untouched: a real ScreenCaptureKit attempt would have written the
        // probe result either way.
        XCTAssertFalse(ScreenCaptureService.probedGranted)
    }
}

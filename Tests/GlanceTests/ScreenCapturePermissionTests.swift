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
}

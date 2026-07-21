import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO

/// Result of a capture: the image plus PNG bytes ready for the backend.
/// We keep bytes in memory only — never written to disk on our side — so FR9's
/// "deleted after the session ends" is satisfied trivially (the bytes are
/// dropped when the overlay session ends). Claude Code still persists its own
/// transcript copy; that's the documented NFR6 trade-off.
struct CaptureResult {
    let image: CGImage
    let pngData: Data
    let displayIndex: Int   // 1-based, for "Display N"
    let pixelWidth: Int
    let pixelHeight: Int

    /// Context-strip label, e.g. "Display 1 · 2560×1440".
    var displayLabel: String { "Display \(displayIndex) · \(pixelWidth)×\(pixelHeight)" }
}

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplay
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required."
        case .noDisplay:
            return "Couldn't find a display to capture."
        case .captureFailed(let m):
            return "Screen capture failed: \(m)"
        }
    }
}

/// FR6/FR7/FR8/FR9: still capture of the active display via ScreenCaptureKit.
enum ScreenCaptureService {

    /// FR7: is Screen Recording (TCC) currently granted?
    /// `CGPreflightScreenCaptureAccess` checks without prompting.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask the system to prompt for Screen Recording once. Returns immediately;
    /// the grant takes effect after the app is relaunched. The guided-prompt UI
    /// (deep link to System Settings) is driven by the caller (FR7).
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Capture a still of the display containing the mouse cursor (FR6).
    /// Alternative "keyboard-focus display" reading rejected in PRD as less
    /// predictable; revisit per FR6 assumption if it feels wrong in use.
    static func captureActiveDisplay() async throws -> CaptureResult {
        guard hasPermission else { throw CaptureError.permissionDenied }

        let targetDisplayID = displayIDUnderCursor()

        // Enumerate shareable displays. Throws if permission is (unexpectedly)
        // missing — treat that as permissionDenied so onboarding can kick in.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }

        let display = content.displays.first(where: { $0.displayID == targetDisplayID })
            ?? content.displays.first
        guard let display else { throw CaptureError.noDisplay }

        // FR8: exclude nothing here, but the overlay window does not yet exist at
        // capture time — the coordinator captures BEFORE showing the panel, which
        // is the reliable way to keep the overlay out of the shot on macOS 15.4+
        // (window-sharing exclusion no longer hides windows from capture).
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scaleFactor(for: targetDisplayID))
        config.height = Int(CGFloat(display.height) * scaleFactor(for: targetDisplayID))
        config.showsCursor = false
        config.captureResolution = .best

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                 configuration: config)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }

        guard let png = pngData(from: cgImage) else {
            throw CaptureError.captureFailed("PNG encode failed")
        }
        let index = (content.displays.firstIndex(where: { $0.displayID == display.displayID }) ?? 0) + 1
        return CaptureResult(image: cgImage,
                             pngData: png,
                             displayIndex: index,
                             pixelWidth: cgImage.width,
                             pixelHeight: cgImage.height)
    }

    /// Small preview of a captured PNG for the overlay's asked header.
    /// ImageIO decodes straight to thumbnail size — the full-resolution bitmap
    /// (tens of MB for a retina display) is never materialized.
    static func thumbnailImage(fromPNG data: Data, maxPixel: CGFloat = 320) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Helpers

    private static func displayIDUnderCursor() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation // global coords, bottom-left origin
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }

    private static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return screen?.backingScaleFactor ?? 2.0
    }

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}

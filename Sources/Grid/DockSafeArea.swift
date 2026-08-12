import AppKit
import CoreGraphics

/// Computes the portion of a full-screen launcher that must remain above a
/// visible bottom Dock. `NSScreen.visibleFrame` is normally sufficient, but
/// it does not always shrink while an auto-hidden Dock is temporarily shown.
/// In that case the public WindowServer window list gives us the actual
/// on-screen Dock frame, avoiding controls or labels being obscured.
enum DockSafeArea {
    /// WindowServer reports window bounds from the global desktop's top-left;
    /// AppKit screen frames use a bottom-left origin. Keep both the
    /// display-local conversion and its single-display fallback isolated and
    /// testable so multi-display Dock detection cannot silently compare values
    /// from two different coordinate systems.
    static func appKitFrame(
        fromWindowServerFrame frame: CGRect,
        windowServerScreenFrame: CGRect,
        appKitScreenFrame: CGRect
    ) -> CGRect {
        guard windowServerScreenFrame.width > 0,
              windowServerScreenFrame.height > 0 else {
            return appKitFrame(fromWindowServerFrame: frame, desktopMaxY: appKitScreenFrame.maxY)
        }

        let scaleX = appKitScreenFrame.width / windowServerScreenFrame.width
        let scaleY = appKitScreenFrame.height / windowServerScreenFrame.height
        let x = appKitScreenFrame.minX + (frame.minX - windowServerScreenFrame.minX) * scaleX
        let width = frame.width * scaleX
        let height = frame.height * scaleY
        let y = appKitScreenFrame.maxY - (frame.maxY - windowServerScreenFrame.minY) * scaleY
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func appKitFrame(fromWindowServerFrame frame: CGRect, desktopMaxY: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: desktopMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func bottomInset(
        hideDock: Bool,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        dockFrames: [CGRect]
    ) -> CGFloat {
        guard !hideDock else { return 0 }

        let visibleFrameInset = max(visibleFrame.minY - screenFrame.minY, 0)
        let dockFrameInset = dockFrames.reduce(CGFloat.zero) { largestInset, frame in
            // A left/right Dock consumes horizontal rather than vertical
            // space. The Dock process also owns full-screen support windows;
            // only a short, wide window attached to the screen's lower edge
            // can be the visible horizontal Dock.
            guard frame.minY <= screenFrame.minY + 1,
                  frame.width >= frame.height,
                  frame.height <= screenFrame.height * 0.25 else {
                return largestInset
            }
            let inset = max(min(frame.maxY, screenFrame.maxY) - screenFrame.minY, 0)
            return max(largestInset, inset)
        }
        return min(max(visibleFrameInset, dockFrameInset), screenFrame.height)
    }

    static func visibleBottomDockFrames(on screen: NSScreen) -> [CGRect] {
        let windowServerScreenFrame = windowServerScreenFrame(for: screen)
        let desktopMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        let dockProcessIDs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .map(\.processIdentifier)
        )
        guard !dockProcessIDs.isEmpty,
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  dockProcessIDs.contains(ownerPID),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }

            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) else {
                return nil
            }
            if let windowServerScreenFrame, !windowServerScreenFrame.intersects(frame) {
                return nil
            }
            let appKitFrame = if let windowServerScreenFrame {
                appKitFrame(
                    fromWindowServerFrame: frame,
                    windowServerScreenFrame: windowServerScreenFrame,
                    appKitScreenFrame: screen.frame
                )
            } else {
                appKitFrame(fromWindowServerFrame: frame, desktopMaxY: desktopMaxY)
            }
            guard appKitFrame.intersects(screen.frame),
                  appKitFrame.width >= appKitFrame.height,
                  appKitFrame.height <= screen.frame.height * 0.25 else {
                return nil
            }
            return appKitFrame
        }
    }

    private static func windowServerScreenFrame(for screen: NSScreen) -> CGRect? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
    }
}

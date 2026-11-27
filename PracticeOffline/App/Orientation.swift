import SwiftUI
import UIKit

/// Which way the screen may turn. The app's settings allow portrait and both landscapes,
/// so iOS is able to rotate into landscape, but everything stays portrait except
/// fullscreen video, which switches this to landscape while it's open.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    /// Allows only `mask` from now on, and turns the screen to match.
    static func set(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                // Ask every screen (including a presented fullscreen one) to re-check.
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: rotationFailed())
        }
    }

    /// iOS may report a failed rotation from a background thread, so this handler must not
    /// belong to the main actor.
    private nonisolated static func rotationFailed() -> @Sendable (any Error) -> Void {
        { error in print("Couldn't rotate the screen:", error) }
    }
}

/// Tells iOS which way the screen may turn right now.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

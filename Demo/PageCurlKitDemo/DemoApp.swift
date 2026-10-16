import UIKit

/// PageCurlKit demo: a small book of static pages turned with a curl on tap.
@main
final class DemoAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = DemoReaderViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

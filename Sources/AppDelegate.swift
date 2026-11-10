import UIKit
import AVFoundation

/// Avvio dell'app: una sola finestra con la schermata del player.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Audio "da film": continua con lo schermo bloccato e permette il Picture in Picture
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = Theme.background
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
        _ = DownloadManager.shared   // riaggancia i download rimasti in corso
        return true
    }

    /// Il sistema riapre l'app quando i download finiscono mentre era chiusa.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletion = completionHandler
    }
}

enum Theme {
    /// Tutti i temi dell'app per iPhone sono su fondo nero
    static let background = UIColor.black
}

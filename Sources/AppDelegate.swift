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
        window.overrideUserInterfaceStyle = Theme.savedStyle
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
    /// Fondo dell'app: quasi nero nel tema scuro, grigio chiaro nel tema chiaro (come la pagina)
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)   // #f2f2f7
            : UIColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1)   // #09090b
    }

    /// Tema scelto nelle impostazioni: "auto" segue l'iPhone, "light" chiaro, "dark" scuro.
    static func style(for mode: String?) -> UIUserInterfaceStyle {
        switch mode {
        case "light": return .light
        case "dark": return .dark
        default: return .unspecified
        }
    }

    /// Il tema salvato, letto all'avvio (così non c'è il lampo di colore sbagliato).
    static var savedStyle: UIUserInterfaceStyle {
        guard let json = SettingsStore.shared.value("xp_mode"),
              let data = json.data(using: .utf8),
              let mode = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
        else { return .unspecified }
        return style(for: mode)
    }
}

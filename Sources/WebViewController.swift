import UIKit
import WebKit
import UniformTypeIdentifiers

/// La schermata dell'app: l'interfaccia (fatta per iPhone) dentro una WKWebView.
/// I file della pagina e le chiamate al server Xtream passano da AppSchemeHandler;
/// i video li riproduce il player nativo (PlayerViewController), con il Picture in Picture automatico.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate {

    private var webView: WKWebView!
    private let schemeHandler = AppSchemeHandler()
    /// nil finché la pagina non dice il tema: la barra di stato segue il sistema
    private var lightPage: Bool?
    private var playerController: PlayerViewController?
    private var multiController: MultiViewController?
    /// Ultimo video aperto: serve per passare al player universale dallo stesso punto.
    private var lastPlayerBody: [String: Any]?
    #if canImport(VLCKit)
    private var universalController: UniversalPlayerViewController?
    #endif

    override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let light = lightPage else { return .default }
        return light ? .darkContent : .lightContent
    }

    /// L'interfaccia resta in verticale; il player invece ruota.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: AppSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Messaggi dalla pagina: salvataggio impostazioni, apertura in VLC, colore della barra di stato
        let controller = WKUserContentController()
        let bridge = MessageBridge(owner: self)
        controller.add(bridge, name: "store")
        controller.add(bridge, name: "external")
        controller.add(bridge, name: "theme")
        controller.add(bridge, name: "player")
        controller.add(bridge, name: "multi")
        controller.add(bridge, name: "download")
        controller.add(bridge, name: "backup")
        controller.add(bridge, name: "open")
        #if canImport(VLCKit)
        // la pagina sa che c'è il player universale
        controller.addUserScript(WKUserScript(source: "window.XP_VLC = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = Theme.background
        web.scrollView.backgroundColor = Theme.background
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        DownloadManager.shared.onChange = { [weak self] in self?.sendDownloads() }
        if let url = URL(string: AppSchemeHandler.scheme + "://app/index.html?ios=1") {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: messaggi dalla pagina

    fileprivate func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "store":
            if let key = body["k"] as? String, let value = body["v"] as? String {
                SettingsStore.shared.set(key, value)
            }
        case "external":
            if let url = body["url"] as? String {
                openInVLC(url)
            }
        case "theme":
            // tema chiaro / scuro scelto nella pagina: vale anche per i menu e le finestre di iOS
            if let mode = body["mode"] as? String, let window = view.window {
                let style = Theme.style(for: mode)
                if window.overrideUserInterfaceStyle != style {
                    window.overrideUserInterfaceStyle = style
                }
            }
            if let light = body["light"] as? Bool {
                lightPage = light
                setNeedsStatusBarAppearanceUpdate()
            }
        case "player":
            handlePlayer(body)
        case "multi":
            handleMulti(body)
        case "download":
            handleDownload(body)
        case "backup":
            handleBackup(body)
        case "open":
            // collegamenti esterni (per esempio il trailer su YouTube): si aprono fuori dall'app
            if let link = body["url"] as? String, let url = URL(string: link), url.scheme == "https" {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        default:
            break
        }
    }

    /// Comandi per il player: apri un contenuto, aggiorna le scritte, chiudi.
    private func handlePlayer(_ body: [String: Any]) {
        let command = (body["cmd"] as? String) ?? ""
        switch command {
        case "open":
            lastPlayerBody = body
            #if canImport(VLCKit)
            if (body["engine"] as? String) == "vlc" {
                openUniversal(body)
                return
            }
            if let universal = universalController {
                // si torna al player dell'iPhone: chiude prima quello universale
                universal.host = nil
                universal.close(notify: false)
                universalController = nil
                if universal.presentingViewController != nil {
                    universal.dismiss(animated: false) { [weak self] in self?.handlePlayer(body) }
                    return
                }
            }
            #endif
            let player = playerController ?? PlayerViewController()
            player.host = self
            playerController = player
            player.load(body)
            if player.presentingViewController == nil && !player.isInPictureInPicture {
                player.modalPresentationStyle = .fullScreen
                present(player, animated: true)
            }
        case "update":
            playerController?.update(body)
            #if canImport(VLCKit)
            universalController?.update(body)
            #endif
        case "close":
            playerController?.close(notify: false)
            #if canImport(VLCKit)
            universalController?.close(notify: false)
            #endif
        default:
            break
        }
    }

    #if canImport(VLCKit)
    /// Apre il player universale (VLC). Se è aperto il player dell'iPhone o il multischermo, li chiude prima.
    private func openUniversal(_ body: [String: Any]) {
        if let universal = universalController, universal.presentingViewController != nil {
            universal.load(body)
            return
        }
        let show: () -> Void = { [weak self] in
            guard let self = self else { return }
            let universal = UniversalPlayerViewController()
            universal.host = self
            self.universalController = universal
            universal.load(body)
            universal.modalPresentationStyle = .fullScreen
            self.present(universal, animated: true)
        }
        if let player = playerController {
            player.host = nil
            player.close(notify: false)
            playerController = nil
            if player.presentingViewController != nil {
                player.dismiss(animated: false, completion: show)
                return
            }
        }
        if let multi = multiController {
            multiController = nil
            multi.host = nil
            multi.close()
            if multi.presentingViewController != nil {
                multi.dismiss(animated: false, completion: show)
                return
            }
        }
        if presentedViewController != nil {
            dismiss(animated: false, completion: show)
            return
        }
        show()
    }
    #endif

    /// Multischermo: più canali insieme. Se c'è il player aperto lo chiude prima.
    private func handleMulti(_ body: [String: Any]) {
        guard (body["cmd"] as? String) == "open" else {
            multiController?.close()
            return
        }
        let show: () -> Void = { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            let multi = MultiViewController()
            multi.host = self
            self.multiController = multi
            multi.load(body)
            multi.modalPresentationStyle = .fullScreen
            self.present(multi, animated: true)
        }
        if let player = playerController {
            player.host = nil
            player.close(notify: false)
            playerController = nil
            if player.presentingViewController != nil {
                player.dismiss(animated: false, completion: show)
                return
            }
        }
        if let old = multiController, old.presentingViewController != nil {
            multiController = nil
            old.host = nil
            old.close()
            old.dismiss(animated: false, completion: show)
            return
        }
        show()
    }

    // MARK: video scaricati

    private func handleDownload(_ body: [String: Any]) {
        let command = (body["cmd"] as? String) ?? ""
        let id = (body["id"] as? String) ?? ""
        switch command {
        case "start":
            guard !id.isEmpty, let link = body["url"] as? String, let url = URL(string: link) else { return }
            DownloadManager.shared.start(id: id, url: url,
                                         title: (body["title"] as? String) ?? "",
                                         sub: (body["sub"] as? String) ?? "",
                                         img: (body["img"] as? String) ?? "",
                                         ext: (body["ext"] as? String) ?? "mp4",
                                         meta: (body["meta"] as? String) ?? "")
        case "remove":
            if !id.isEmpty { DownloadManager.shared.remove(id: id) }
        default:
            sendDownloads()
        }
    }

    private func sendDownloads() {
        sendEvent("downloads", ["items": DownloadManager.shared.list()])
    }

    // MARK: copia dei dati da portare sugli altri dispositivi

    private func handleBackup(_ body: [String: Any]) {
        if (body["cmd"] as? String) == "export" {
            guard let text = body["text"] as? String else { return }
            let name = (body["name"] as? String) ?? "xtream-dati.json"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do { try text.write(to: file, atomically: true, encoding: .utf8) } catch { return }
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(share, animated: true)
        } else {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.json, UTType.plainText, UTType.data], asCopy: true)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let data = try? Data(contentsOf: url), data.count < 20_000_000,
              let text = String(data: data, encoding: .utf8) else {
            sendEvent("import", ["text": ""])
            return
        }
        sendEvent("import", ["text": text])
    }

    fileprivate func sendEvent(_ event: String, _ data: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(data),
              let json = try? JSONSerialization.data(withJSONObject: data, options: []),
              let text = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.XP && window.XP.ev(" + SettingsStore.quote(event) + "," + text + ")", completionHandler: nil)
    }

    /// Apre il video in VLC (gratis sull'App Store), per i formati che il player di iOS non legge.
    fileprivate func openInVLC(_ link: String) {
        var comps = URLComponents()
        comps.scheme = "vlc-x-callback"
        comps.host = "x-callback-url"
        comps.path = "/stream"
        comps.queryItems = [URLQueryItem(name: "url", value: link)]
        guard let target = comps.url else { return }
        UIApplication.shared.open(target, options: [:]) { [weak self] ok in
            if !ok {
                self?.webView.evaluateJavaScript("window.nativeExternalFailed && window.nativeExternalFailed()", completionHandler: nil)
            }
        }
    }

    // MARK: navigazione

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme ?? ""
        decisionHandler(scheme == AppSchemeHandler.scheme || scheme == "about" ? .allow : .cancel)
    }

    /// Se il motore della pagina si chiude (per esempio per poca memoria), la ricarica.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: finestre di avviso della pagina (alert, conferma, testo)

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}

// MARK: eventi del player verso la pagina

extension WebViewController: PlayerHost {

    func player(_ player: PlayerViewController, event: String, data: [String: Any]) {
        sendEvent(event, data)
    }

    /// Picture in Picture partito (dal pulsante o uscendo dall'app): torna l'interfaccia, il video resta nella finestrina.
    func playerDidStartPictureInPicture(_ player: PlayerViewController) {
        // il riquadro del video resta nella finestra: senza, il miniplayer si blocca mentre l'audio va avanti
        if let window = view.window { player.parkVideo(in: window) }
        if player.presentingViewController != nil {
            player.dismiss(animated: true, completion: nil)
        }
    }

    /// Dalla finestrina si torna al player a tutto schermo.
    func playerRestoreFromPictureInPicture(_ player: PlayerViewController, completion: @escaping (Bool) -> Void) {
        if player.presentingViewController != nil {
            completion(true)
            return
        }
        let show: () -> Void = { [weak self] in
            guard let self = self else { completion(false); return }
            player.modalPresentationStyle = .fullScreen
            self.present(player, animated: true) { completion(true) }
        }
        // prima c'era un'altra finestra aperta (un avviso, la condivisione…) e il video spariva:
        // ora si chiude quella e il player torna a tutto schermo
        if let other = presentedViewController {
            other.dismiss(animated: false, completion: show)
        } else {
            show()
        }
    }

    func playerDidClose(_ player: PlayerViewController) {
        if player.presentingViewController != nil {
            player.dismiss(animated: true, completion: nil)
        }
        if playerController === player {
            playerController = nil
        }
    }

    /// Pulsante "Universale" o formato non letto dall'iPhone: continua nel player universale dallo stesso punto.
    /// Senza il player universale apre l'app VLC.
    func playerOpenExternal(_ player: PlayerViewController, url: String) {
        #if canImport(VLCKit)
        if var body = lastPlayerBody {
            body["engine"] = "vlc"
            if let raw = body["vlc"] as? String, !raw.isEmpty { body["url"] = raw }
            let t = player.playbackSeconds
            if t > 5 { body["start"] = t }
            openUniversal(body)
            return
        }
        #endif
        openInVLC(url)
    }
}

#if canImport(VLCKit)
extension WebViewController: UniversalPlayerHost {

    func universal(_ player: UniversalPlayerViewController, event: String, data: [String: Any]) {
        sendEvent(event, data)
    }

    func universalDidClose(_ player: UniversalPlayerViewController) {
        PlaybackAudio.activate()
        if player.presentingViewController != nil {
            player.dismiss(animated: true, completion: nil)
        }
        if universalController === player {
            universalController = nil
        }
    }
}
#endif

// MARK: eventi del multischermo verso la pagina

extension WebViewController: MultiHost {

    func multiDidClose(_ multi: MultiViewController, ids: [String]) {
        if multiController === multi { multiController = nil }
        if multi.presentingViewController != nil {
            multi.dismiss(animated: true, completion: nil)
        }
        sendEvent("multiClosed", ["ids": ids])
    }

    /// Un riquadro va a schermo intero: prima si chiude il multischermo, poi la pagina apre il player normale.
    func multiWantsFullScreen(_ multi: MultiViewController, id: String, ids: [String]) {
        if multiController === multi { multiController = nil }
        let go: () -> Void = { [weak self] in
            self?.sendEvent("multiFull", ["id": id, "ids": ids])
        }
        if multi.presentingViewController != nil {
            multi.dismiss(animated: false, completion: go)
        } else {
            go()
        }
    }
}

/// Riceve i messaggi della pagina senza trattenere la schermata (evita cicli di memoria).
private final class MessageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewController?

    init(owner: WebViewController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handle(message)
    }
}

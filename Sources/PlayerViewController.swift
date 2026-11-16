import UIKit
import AVFoundation
import AVKit
import MediaPlayer

/// Chi ospita il player (la schermata principale): riceve gli eventi e lo mostra o lo nasconde.
protocol PlayerHost: AnyObject {
    func player(_ player: PlayerViewController, event: String, data: [String: Any])
    func playerDidStartPictureInPicture(_ player: PlayerViewController)
    func playerRestoreFromPictureInPicture(_ player: PlayerViewController, completion: @escaping (Bool) -> Void)
    func playerDidClose(_ player: PlayerViewController)
    func playerOpenExternal(_ player: PlayerViewController, url: String)
}

/// Vista che contiene direttamente il video.
final class PlayerVideoView: UIView {
    override class var layerClass: AnyClass { return AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { return layer as! AVPlayerLayer }
}

/// Sfumatura scura dietro ai comandi, perché restino leggibili su qualsiasi immagine.
final class GradientView: UIView {
    override class var layerClass: AnyClass { return CAGradientLayer.self }

    init(fromTop: Bool) {
        super.init(frame: .zero)
        let gradient = layer as! CAGradientLayer
        let dark = UIColor.black.withAlphaComponent(0.72).cgColor
        let clear = UIColor.black.withAlphaComponent(0).cgColor
        gradient.colors = fromTop ? [dark, clear] : [clear, dark]
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }
}

/// Etichetta con un po' di margine interno (per i badge e i messaggi brevi).
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// Il player video dell'app.
/// In alto: chiudi, titolo, AirPlay e Picture in Picture. Al centro: riproduci e salti.
/// In basso: barra del tempo (o "In diretta") e una fila di comandi, ognuno al suo posto.
/// Il Picture in Picture parte da solo quando esci dall'app mentre il video è in riproduzione.
final class PlayerViewController: UIViewController, AVPictureInPictureControllerDelegate, UIGestureRecognizerDelegate {

    weak var host: PlayerHost?
    let player = AVPlayer()
    private(set) var isInPictureInPicture = false

    // MARK: stato del contenuto

    private var url: URL?
    private var externalURL = ""
    private var isLive = false
    private var isCatchup = false
    private var startAt: Double = 0
    private var zapNames: [String] = []
    private var zapIndex = 0
    private var zapTitle = "Canali"
    private var nextTitle: String?
    private var autoNext = true
    private var nextShown = false
    private var isFav: Bool?
    private var retried = false
    private var wantsFallback = false   // se il canale non parte, la pagina può proporne uno alternativo
    private var canSkipIntro = false
    private var loadCount = 0
    private var restoring = false
    private var closing = false
    private var scrubbing = false
    private var controlsVisible = true
    private var pausedAt: Date?
    private var lastReport = Date.distantPast
    private var sleepMinutes = 0
    private var sleepUntil: Date?
    private var forcedMask: UIInterfaceOrientationMask?
    private var speed: Float = 1
    private var panMode = 0            // 0 niente, 1 luminosità, 2 volume
    private var panStart: Double = 0
    private var savedBrightness: CGFloat?
    private var doubleTapGesture: UITapGestureRecognizer?
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))
    private var accent = UIColor(red: 0.31, green: 0.48, blue: 1.0, alpha: 1)

    // MARK: osservatori e timer

    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    private var hideTimer: Timer?
    private var nextTimer: Timer?
    private var watchdog: Timer?
    private var toastTimer: Timer?
    private var pipController: AVPictureInPictureController?

    // MARK: interfaccia

    private let videoView = PlayerVideoView()
    private let controls = UIView()
    private let topShade = GradientView(fromTop: true)
    private let bottomShade = GradientView(fromTop: false)
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let rotateButton = UIButton(type: .system)
    private let routePicker = AVRoutePickerView()
    private let pipButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let progressRow = UIStackView()
    private let liveBadge = PaddedLabel()
    private let liveInfoLabel = UILabel()
    private let liveRow = UIStackView()
    private let actionBar = UIStackView()
    private let channelsItem = PlayerViewController.actionButton("list.bullet", "Canali")
    private let multiItem = PlayerViewController.actionButton("square.grid.2x2", "Multi")
    private let audioItem = PlayerViewController.actionButton("captions.bubble", "Audio")
    private let fitItem = PlayerViewController.actionButton("aspectratio", "Formato")
    private let sleepItem = PlayerViewController.actionButton("moon.zzz", "Timer")
    private let speedItem = PlayerViewController.actionButton("speedometer", "Velocità")
    private let favItem = PlayerViewController.actionButton("star", "Preferito")
    #if canImport(MobileVLCKit)
    private let vlcItem = PlayerViewController.actionButton("play.rectangle.on.rectangle", "Universale")
    #else
    private let vlcItem = PlayerViewController.actionButton("arrow.up.right.square", "VLC")
    #endif
    private let numberItem = PlayerViewController.actionButton("number", "Numero")
    private let skipItem = PlayerViewController.actionButton("forward.end", "Salta 90 s")
    private let errorBox = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let errorTitle = UILabel()
    private let errorMessage = UILabel()
    private let retryButton = UIButton(type: .system)
    private let errorVLCButton = UIButton(type: .system)
    private let nextBox = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let nextLabel = UILabel()
    private let nextGo = UIButton(type: .system)
    private let nextCancel = UIButton(type: .system)
    private let toastLabel = PaddedLabel()

    // MARK: ciclo di vita

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        buildInterface()

        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect

        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: videoView.playerLayer) {
            pip.delegate = self
            if #available(iOS 14.2, *) {
                pip.canStartPictureInPictureAutomaticallyFromInline = true
            }
            pipController = pip
        }
        pipButton.isHidden = pipController == nil

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.tick()
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.playbackStateChanged() }
        }
        setupRemoteCommands()
        buildSleepMenu()
        buildSpeedMenu()
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return forcedMask ?? .allButUpsideDown
    }

    override var prefersStatusBarHidden: Bool { return !controlsVisible }
    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { return !controlsVisible }

    // MARK: comandi dalla pagina

    /// Apre un contenuto. Se il player è già aperto (o in Picture in Picture) cambia solo il video.
    func load(_ body: [String: Any]) {
        loadViewIfNeeded()
        closing = false
        guard let link = body["url"] as? String, let target = URL(string: link) else {
            showError("Indirizzo non valido", "Non riesco ad aprire questo contenuto.")
            return
        }
        url = target
        externalURL = (body["vlc"] as? String) ?? link
        isLive = (body["live"] as? Bool) ?? false
        isCatchup = (body["catchup"] as? Bool) ?? false
        startAt = (body["start"] as? NSNumber)?.doubleValue ?? 0
        titleLabel.text = (body["title"] as? String) ?? ""
        subtitleLabel.text = (body["sub"] as? String) ?? ""
        liveInfoLabel.text = ""
        autoNext = (body["autonext"] as? Bool) ?? true
        nextTitle = (body["next"] as? [String: Any])?["title"] as? String
        wantsFallback = (body["fallback"] as? Bool) ?? false
        canSkipIntro = (body["skip"] as? Bool) ?? false
        loadCount += 1
        isFav = body["fav"] as? Bool
        if let hex = body["accent"] as? String, let color = PlayerViewController.color(hex: hex) {
            accent = color
            applyAccent()
        }
        if let zap = body["zap"] as? [String: Any], let list = zap["list"] as? [[String: Any]] {
            zapNames = list.map { item in
                let num = (item["num"] as? String) ?? ""
                let name = (item["name"] as? String) ?? ""
                return num.isEmpty ? name : num + "   " + name
            }
            zapIndex = (zap["i"] as? NSNumber)?.intValue ?? 0
            zapTitle = (zap["name"] as? String) ?? "Canali"
        } else {
            zapNames = []
            zapIndex = 0
        }
        if let fill = body["fill"] as? Bool {
            videoView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            refreshFitItem()
        }
        retried = false
        nextShown = false
        speed = 1
        PlayerViewController.setItem(speedItem, symbol: "speedometer", title: "Velocità")
        buildSpeedMenu()
        configureForContent()
        startPlayback()
        setControls(true)
    }

    /// Aggiorna le scritte mentre il video va (programma in onda, preferito).
    func update(_ body: [String: Any]) {
        loadViewIfNeeded()
        if let sub = body["sub"] as? String { subtitleLabel.text = sub }
        if let info = body["info"] as? String { liveInfoLabel.text = info }
        if let toast = body["toast"] as? String { showToast(toast) }
        if let fav = body["fav"] as? Bool {
            isFav = fav
            refreshFavItem()
        }
        updateNowPlaying()
    }

    /// Chiude il player. Con notify la pagina riceve il punto in cui eri arrivato.
    func close(notify: Bool) {
        if closing { return }
        closing = true
        if notify {
            var data: [String: Any] = [:]
            if let item = player.currentItem {
                let t = player.currentTime().seconds, d = item.duration.seconds
                if t.isFinite && d.isFinite && d > 0 { data = ["t": t, "d": d] }
            }
            host?.player(self, event: "closed", data: data)
        }
        watchdog?.invalidate()
        hideTimer?.invalidate()
        nextTimer?.invalidate()
        toastTimer?.invalidate()
        sleepUntil = nil
        if let brightness = savedBrightness {
            UIScreen.main.brightness = brightness
            savedBrightness = nil
        }
        player.pause()
        clearItemObservers()
        player.replaceCurrentItem(with: nil)
        if let pip = pipController, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        removeRemoteCommands()
        host?.playerDidClose(self)
    }

    // MARK: riproduzione

    private func startPlayback() {
        guard let target = url else { return }
        clearItemObservers()
        hideError()
        hideNext()
        spinner.startAnimating()
        let item = AVPlayerItem(url: target)
        if isLive { item.preferredForwardBufferDuration = 8 }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(observed) }
        }
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.didReachEnd()
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            self?.failed(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error, timeout: false)
        })
        PlaybackAudio.activate()
        player.replaceCurrentItem(with: item)
        player.play()
        armWatchdog()
        updateNowPlaying()
    }

    private func clearItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers.removeAll()
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if startAt > 1 {
                let time = CMTime(seconds: startAt, preferredTimescale: 600)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
                showToast("Ripreso da " + PlayerViewController.format(startAt))
                startAt = 0
            }
            buildAudioMenu(item)
            updateNowPlaying()
        case .failed:
            failed(item.error, timeout: false)
        default:
            break
        }
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, let item = self.player.currentItem else { return }
            if item.status != .readyToPlay || (self.player.timeControlStatus != .playing && self.player.currentTime().seconds < 0.5) {
                self.failed(nil, timeout: true)
            }
        }
    }

    private func failed(_ error: Error?, timeout: Bool) {
        watchdog?.invalidate()
        let status = player.currentItem?.errorLog()?.events.last?.errorStatusCode ?? 0
        let refused = [401, 403, 429, 458, 509].contains(status)
        if !retried && !refused && (isLive || isCatchup || timeout) {
            // un secondo tentativo automatico: le dirette a volte non rispondono al primo colpo
            retried = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, !self.closing else { return }
                self.startPlayback()
            }
            return
        }
        if isLive && wantsFallback && !refused {
            // chiede alla pagina un canale alternativo; se non arriva entro poco, mostra l'errore
            let attempt = loadCount
            host?.player(self, event: "fail", data: [:])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, !self.closing, self.loadCount == attempt else { return }
                self.spinner.stopAnimating()
                self.showError("Il canale non risponde", "Potrebbe essere offline in questo momento e non ho trovato un canale alternativo. Riprova tra poco.")
            }
            return
        }
        spinner.stopAnimating()
        let what = isLive ? "Il canale" : "Il contenuto"
        let domain = (error as NSError?)?.domain ?? ""
        if refused {
            showError("Il server rifiuta la connessione",
                      "Probabilmente hai raggiunto il numero massimo di connessioni del tuo abbonamento. Chiudi l'app sugli altri dispositivi, aspetta qualche secondo e riprova.")
        } else if timeout || status == 404 || status >= 500 || domain == NSURLErrorDomain {
            showError(what + " non risponde",
                      (isLive ? "Potrebbe essere offline in questo momento." : "Il server non lo sta inviando in questo momento.") + " Riprova tra poco, oppure prova " + PlayerViewController.otherPlayer + ".")
        } else {
            #if canImport(MobileVLCKit)
            // formato che l'iPhone non legge: passa da solo al player universale, dal punto in cui eri
            host?.playerOpenExternal(self, url: externalURL)
            return
            #endif
            showError("Formato non supportato",
                      what + " usa un formato che il player dell'iPhone non legge (per esempio MKV o audio Dolby). In VLC si vede normalmente.")
        }
    }

    private func didReachEnd() {
        guard !isLive else { return }
        host?.player(self, event: "ended", data: [:])
        if let next = nextTitle, autoNext {
            showNext(next, countdown: true)
        } else {
            setControls(true)
        }
    }

    private func tick() {
        guard let item = player.currentItem else { return }
        let t = player.currentTime().seconds
        let d = item.duration.seconds
        if !isLive && d.isFinite && d > 0 && t.isFinite {
            if !scrubbing {
                slider.value = Float(min(1, max(0, t / d)))
                elapsedLabel.text = PlayerViewController.format(t)
                remainingLabel.text = "-" + PlayerViewController.format(max(0, d - t))
            }
            if let next = nextTitle, !nextShown, d > 300, d - t < 60, d - t > 1 {
                nextShown = true
                showNext(next, countdown: false)
            }
        }
        if Date().timeIntervalSince(lastReport) > 5 { reportTime() }
        if let until = sleepUntil, Date() >= until {
            sleepUntil = nil
            close(notify: true)
        }
    }

    private func reportTime() {
        lastReport = Date()
        guard !isLive, let item = player.currentItem else { return }
        let t = player.currentTime().seconds, d = item.duration.seconds
        guard t.isFinite, d.isFinite, d > 0 else { return }
        host?.player(self, event: "time", data: ["t": t, "d": d])
    }

    private func playbackStateChanged() {
        switch player.timeControlStatus {
        case .playing:
            spinner.stopAnimating()
            watchdog?.invalidate()
            pausedAt = nil
            if !isLive && speed != 1 && abs(player.rate - speed) > 0.01 { player.rate = speed }
            scheduleHide()
        case .waitingToPlayAtSpecifiedRate:
            if errorBox.isHidden { spinner.startAnimating() }
        case .paused:
            spinner.stopAnimating()
            if pausedAt == nil { pausedAt = Date() }
            reportTime()
        @unknown default:
            break
        }
        refreshPlayIcon()
        updateNowPlaying()
    }

    // MARK: azioni dei pulsanti

    @objc private func closeTapped() { close(notify: true) }

    @objc private func togglePlay() {
        if player.timeControlStatus == .paused {
            if isLive, let since = pausedAt, Date().timeIntervalSince(since) > 20 {
                startPlayback()   // dopo una pausa lunga riparte dal momento attuale della diretta
                return
            }
            if let item = player.currentItem, item.duration.seconds.isFinite,
               player.currentTime().seconds >= item.duration.seconds - 0.5 {
                player.seek(to: .zero)
            }
            player.play()
            applySpeed()
        } else {
            player.pause()
        }
        scheduleHide()
    }

    @objc private func backTapped() {
        if isLive { zap(-1) } else { seek(by: -10) }
    }

    @objc private func forwardTapped() {
        if isLive { zap(1) } else { seek(by: 10) }
    }

    private func seek(by seconds: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        var target = max(0, now + seconds)
        if let d = player.currentItem?.duration.seconds, d.isFinite { target = min(target, max(0, d - 1)) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        scheduleHide()
    }

    private func zap(_ delta: Int) {
        guard !zapNames.isEmpty else { return }
        let count = zapNames.count
        let index = ((zapIndex + delta) % count + count) % count
        host?.player(self, event: "zap", data: ["i": index])
    }

    @objc private func showChannels() {
        guard !zapNames.isEmpty else { return }
        let list = ChannelListViewController(title: zapTitle, names: zapNames, selected: zapIndex) { [weak self] index in
            guard let self = self else { return }
            self.host?.player(self, event: "zap", data: ["i": index])
        }
        let nav = UINavigationController(rootViewController: list)
        nav.overrideUserInterfaceStyle = .dark
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        hideTimer?.invalidate()
        present(nav, animated: true)
    }

    @objc private func toggleFit() {
        let fill = videoView.playerLayer.videoGravity != .resizeAspectFill
        videoView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        refreshFitItem()
        showToast(fill ? "Riempi lo schermo" : "Adatta allo schermo")
        host?.player(self, event: "fit", data: ["fill": fill])
        scheduleHide()
    }

    @objc private func favTapped() {
        guard let fav = isFav else { return }
        isFav = !fav
        refreshFavItem()
        showToast(fav ? "Tolto dai preferiti" : "Aggiunto ai preferiti")
        host?.player(self, event: "fav", data: [:])
        scheduleHide()
    }

    /// Dalla diretta al multischermo: la pagina chiude questo player e apre i riquadri con questo canale.
    /// Salta la sigla: avanti di un minuto e mezzo.
    @objc private func skipTapped() {
        seek(by: 90)
        showToast("Avanti di 90 secondi")
    }

    /// Scrivi il numero del canale, come con un telecomando.
    @objc private func numberTapped() {
        let alert = UIAlertController(title: "Vai al canale", message: "Scrivi il numero del canale.", preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .dark
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = "Numero"
            field.textAlignment = .center
        }
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { [weak self] _ in self?.scheduleHide() })
        alert.addAction(UIAlertAction(title: "Vai", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let digits = (alert?.textFields?.first?.text ?? "").filter { $0.isNumber }
            self.scheduleHide()
            if !digits.isEmpty { self.host?.player(self, event: "num", data: ["n": digits]) }
        })
        hideTimer?.invalidate()
        present(alert, animated: true)
    }

    @objc private func multiTapped() {
        host?.player(self, event: "multi", data: [:])
    }

    @objc private func vlcTapped() {
        player.pause()
        host?.playerOpenExternal(self, url: externalURL)
    }

    @objc private func retryTapped() {
        retried = false
        startPlayback()
    }

    @objc private func pipTapped() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            showToast("Il Picture in Picture è disponibile quando il video è partito")
        }
    }

    @objc private func rotateTapped() {
        let landscape = view.bounds.width > view.bounds.height
        let wanted: UIInterfaceOrientationMask = landscape ? .portrait : .landscapeRight
        forcedMask = landscape ? nil : .landscape
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: wanted))
        } else {
            let orientation: UIInterfaceOrientation = landscape ? .portrait : .landscapeRight
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        scheduleHide()
    }

    @objc private func nextGoTapped() { requestNext() }

    @objc private func menuOpened() {
        hideTimer?.invalidate()
    }

    @objc private func nextCancelTapped() {
        nextTimer?.invalidate()
        hideNext()
    }

    private func requestNext() {
        nextTimer?.invalidate()
        hideNext()
        host?.player(self, event: "next", data: [:])
    }

    // MARK: barra del tempo

    @objc private func sliderBegan() {
        scrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func sliderChanged() {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        let t = Double(slider.value) * d
        elapsedLabel.text = PlayerViewController.format(t)
        remainingLabel.text = "-" + PlayerViewController.format(max(0, d - t))
    }

    @objc private func sliderEnded() {
        defer { scrubbing = false; scheduleHide() }
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        player.seek(to: CMTime(seconds: Double(slider.value) * d, preferredTimescale: 600))
    }

    // MARK: comandi visibili o nascosti

    @objc private func viewTapped() {
        setControls(!controlsVisible)
    }

    /// Doppio tocco: a sinistra torna indietro di 10 secondi, a destra va avanti (solo film ed episodi).
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard !isLive else { return }
        let left = gesture.location(in: view).x < view.bounds.width / 2
        seek(by: left ? -10 : 10)
        showToast(left ? "10 secondi indietro" : "10 secondi avanti")
    }

    /// Scorrimento in verticale: metà sinistra dello schermo per la luminosità, metà destra per il volume.
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let velocity = gesture.velocity(in: view)
            guard abs(velocity.y) > abs(velocity.x) else {
                panMode = 0
                return
            }
            let left = gesture.location(in: view).x < view.bounds.width / 2
            panMode = left ? 1 : 2
            if left {
                if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
                panStart = Double(UIScreen.main.brightness)
            } else {
                panStart = Double(volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
            }
        case .changed:
            guard panMode != 0 else { return }
            let travel = max(220, view.bounds.height * 0.55)
            let value = min(1, max(0, panStart - Double(gesture.translation(in: view).y / travel)))
            if panMode == 1 {
                UIScreen.main.brightness = CGFloat(value)
                showToast("Luminosità \(Int((value * 100).rounded()))%")
            } else {
                volumeSlider?.value = Float(value)
                showToast("Volume \(Int((value * 100).rounded()))%")
            }
        default:
            panMode = 0
        }
    }

    private var volumeSlider: UISlider? {
        return volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private func buildSpeedMenu() {
        let options: [(String, Float)] = [("0,5x", 0.5), ("0,75x", 0.75), ("Normale", 1), ("1,25x", 1.25), ("1,5x", 1.5), ("2x", 2)]
        let actions = options.map { option in
            UIAction(title: option.0, state: option.1 == speed ? .on : .off) { [weak self] _ in
                self?.setSpeed(option.1, label: option.0)
            }
        }
        speedItem.menu = UIMenu(title: "Velocità di riproduzione", children: actions)
        speedItem.showsMenuAsPrimaryAction = true
    }

    private func setSpeed(_ value: Float, label: String) {
        speed = value
        PlayerViewController.setItem(speedItem, symbol: "speedometer", title: value == 1 ? "Velocità" : label)
        buildSpeedMenu()
        applySpeed()
        scheduleHide()
        showToast(value == 1 ? "Velocità normale" : "Velocità " + label)
    }

    private func applySpeed() {
        guard !isLive, player.timeControlStatus != .paused else { return }
        player.rate = speed
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let fill = videoView.playerLayer.videoGravity == .resizeAspectFill
        if gesture.scale > 1.1 && !fill { toggleFit() }
        if gesture.scale < 0.9 && fill { toggleFit() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let v = current {
            if v is UIControl || v === errorBox || v === nextBox { return false }
            current = v.superview
        }
        return true
    }

    private func setControls(_ visible: Bool, animated: Bool = true) {
        controlsVisible = visible
        UIView.animate(withDuration: animated ? 0.22 : 0) {
            self.controls.alpha = visible ? 1 : 0
        }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        if visible { scheduleHide() } else { hideTimer?.invalidate() }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.player.timeControlStatus == .playing && !self.scrubbing
                && self.errorBox.isHidden && self.presentedViewController == nil {
                self.setControls(false)
            }
        }
    }

    // MARK: Picture in Picture

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isInPictureInPicture = true
        setControls(false, animated: false)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        host?.playerDidStartPictureInPicture(self)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isInPictureInPicture = false
        showToast("Picture in Picture non disponibile")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        if let host = host {
            host.playerRestoreFromPictureInPicture(self, completion: completionHandler)
        } else {
            completionHandler(false)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isInPictureInPicture = false
        let wasRestoring = restoring
        restoring = false
        // chiusa con la X della finestrina (senza tornare nell'app): il video finisce lì
        if !wasRestoring && presentingViewController == nil {
            close(notify: true)
            return
        }
        setControls(true)
    }

    // MARK: menu audio, sottotitoli e timer

    private func buildAudioMenu(_ item: AVPlayerItem) {
        var sections: [UIMenuElement] = []
        let asset = item.asset
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible), group.options.count > 1 {
            let current = item.currentMediaSelection.selectedMediaOption(in: group)
            let actions = group.options.map { option in
                UIAction(title: option.displayName, state: option == current ? .on : .off) { [weak self, weak item] _ in
                    item?.select(option, in: group)
                    if let it = item { self?.buildAudioMenu(it) }
                    self?.scheduleHide()
                }
            }
            sections.append(UIMenu(title: "Audio", options: .displayInline, children: actions))
        }
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .legible), !group.options.isEmpty {
            let current = item.currentMediaSelection.selectedMediaOption(in: group)
            var actions = [UIAction(title: "Nessuno", state: current == nil ? .on : .off) { [weak self, weak item] _ in
                item?.select(nil, in: group)
                if let it = item { self?.buildAudioMenu(it) }
            }]
            actions += group.options.map { option in
                UIAction(title: option.displayName, state: option == current ? .on : .off) { [weak self, weak item] _ in
                    item?.select(option, in: group)
                    if let it = item { self?.buildAudioMenu(it) }
                    self?.scheduleHide()
                }
            }
            sections.append(UIMenu(title: "Sottotitoli", options: .displayInline, children: actions))
        }
        if sections.isEmpty {
            audioItem.menu = nil
            audioItem.isEnabled = false
            audioItem.alpha = 0.4
        } else {
            audioItem.menu = UIMenu(title: "", children: sections)
            audioItem.showsMenuAsPrimaryAction = true
            audioItem.isEnabled = true
            audioItem.alpha = 1
        }
    }

    private func buildSleepMenu() {
        let options: [(String, Int)] = [("Disattivato", 0), ("Tra 15 minuti", 15), ("Tra 30 minuti", 30), ("Tra 1 ora", 60), ("Tra 1 ora e mezza", 90)]
        let actions = options.map { option in
            UIAction(title: option.0, state: option.1 == sleepMinutes ? .on : .off) { [weak self] _ in
                self?.setSleep(option.1)
            }
        }
        sleepItem.menu = UIMenu(title: "Ferma la riproduzione", children: actions)
        sleepItem.showsMenuAsPrimaryAction = true
    }

    private func setSleep(_ minutes: Int) {
        sleepMinutes = minutes
        sleepUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        PlayerViewController.setItem(sleepItem, symbol: minutes > 0 ? "moon.zzz.fill" : "moon.zzz",
                                     title: minutes > 0 ? "\(minutes) min" : "Timer")
        buildSleepMenu()
        scheduleHide()
        showToast(minutes > 0 ? "La riproduzione si fermerà tra \(minutes) minuti" : "Timer disattivato")
    }

    // MARK: aspetto

    private func configureForContent() {
        progressRow.isHidden = isLive
        liveRow.isHidden = !isLive
        let big = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        backButton.setImage(UIImage(systemName: isLive ? "backward.end.fill" : "gobackward.10", withConfiguration: big), for: .normal)
        forwardButton.setImage(UIImage(systemName: isLive ? "forward.end.fill" : "goforward.10", withConfiguration: big), for: .normal)
        backButton.accessibilityLabel = isLive ? "Canale precedente" : "Indietro di 10 secondi"
        forwardButton.accessibilityLabel = isLive ? "Canale successivo" : "Avanti di 10 secondi"
        let canZap = zapNames.count > 1
        backButton.isHidden = isLive && !canZap
        forwardButton.isHidden = isLive && !canZap
        channelsItem.isHidden = zapNames.isEmpty
        multiItem.isHidden = !isLive
        vlcItem.isHidden = isLive || (url?.isFileURL ?? false)   // un video scaricato si guarda qui, senza VLC
        speedItem.isHidden = isLive
        numberItem.isHidden = !isLive
        skipItem.isHidden = isLive || !canSkipIntro
        doubleTapGesture?.isEnabled = !isLive
        favItem.isHidden = isFav == nil
        refreshFavItem()
        refreshFitItem()
        audioItem.menu = nil
        audioItem.isEnabled = false
        audioItem.alpha = 0.4
        slider.value = 0
        elapsedLabel.text = "0:00"
        remainingLabel.text = "-0:00"
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = isLive && canZap
        commands.previousTrackCommand.isEnabled = isLive && canZap
        commands.skipForwardCommand.isEnabled = !isLive
        commands.skipBackwardCommand.isEnabled = !isLive
        commands.changePlaybackPositionCommand.isEnabled = !isLive
    }

    private func refreshPlayIcon() {
        let paused = player.timeControlStatus == .paused
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        playButton.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill", withConfiguration: config), for: .normal)
        playButton.accessibilityLabel = paused ? "Riproduci" : "Pausa"
    }

    private func refreshFavItem() {
        let on = isFav ?? false
        PlayerViewController.setItem(favItem, symbol: on ? "star.fill" : "star", title: "Preferito")
        favItem.tintColor = on ? accent : .white
        if var config = favItem.configuration {
            config.baseForegroundColor = on ? accent : .white
            favItem.configuration = config
        }
    }

    private func refreshFitItem() {
        let fill = videoView.playerLayer.videoGravity == .resizeAspectFill
        PlayerViewController.setItem(fitItem, symbol: fill ? "arrow.down.right.and.arrow.up.left" : "aspectratio",
                                     title: fill ? "Riempi" : "Adatta")
    }

    private func applyAccent() {
        slider.minimumTrackTintColor = accent
        routePicker.activeTintColor = accent
        refreshFavItem()
    }

    private func showError(_ title: String, _ message: String) {
        errorTitle.text = title
        errorMessage.text = message
        errorVLCButton.isHidden = url?.isFileURL ?? false
        errorBox.isHidden = false
        playButton.isHidden = true
        backButton.alpha = 0
        forwardButton.alpha = 0
        spinner.stopAnimating()
        setControls(true)
    }

    private func hideError() {
        errorBox.isHidden = true
        playButton.isHidden = false
        backButton.alpha = 1
        forwardButton.alpha = 1
    }

    private func showNext(_ title: String, countdown: Bool) {
        nextLabel.text = "Prossimo episodio\n" + title
        nextBox.isHidden = false
        nextTimer?.invalidate()
        guard countdown else {
            PlayerViewController.setTitle(nextGo, "Guarda ora")
            return
        }
        var left = 10
        PlayerViewController.setTitle(nextGo, "Guarda ora (\(left))")
        nextTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            left -= 1
            if left <= 0 {
                timer.invalidate()
                self.requestNext()
            } else {
                UIView.performWithoutAnimation {
                    PlayerViewController.setTitle(self.nextGo, "Guarda ora (\(left))")
                    self.nextGo.layoutIfNeeded()
                }
            }
        }
    }

    private func hideNext() {
        nextBox.isHidden = true
    }

    private func showToast(_ text: String) {
        toastLabel.text = text
        toastTimer?.invalidate()
        UIView.animate(withDuration: 0.18) { self.toastLabel.alpha = 1 }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.3) { self?.toastLabel.alpha = 0 }
        }
    }

    // MARK: Centro di controllo e schermata di blocco

    private func setupRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            self?.player.play()
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.isLive else { return .noActionableNowPlayingItem }
            self.zap(1)
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.isLive else { return .noActionableNowPlayingItem }
            self.zap(-1)
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(by: 10)
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(by: -10)
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let change = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: CMTime(seconds: change.positionTime, preferredTimescale: 600))
            return .success
        }
    }

    private func removeRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
         commands.nextTrackCommand, commands.previousTrackCommand, commands.skipForwardCommand,
         commands.skipBackwardCommand, commands.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: titleLabel.text ?? "",
            MPMediaItemPropertyArtist: subtitleLabel.text ?? "",
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate)
        ]
        if !isLive, let item = player.currentItem {
            let d = item.duration.seconds, t = player.currentTime().seconds
            if d.isFinite && d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
            if t.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: costruzione dell'interfaccia

    private func buildInterface() {
        let safe = view.safeAreaLayoutGuide

        // video
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        // comandi (spariscono dopo qualche secondo)
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        [topShade, bottomShade].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview($0)
        }

        // barra in alto: chiudi, titolo, ruota, AirPlay, Picture in Picture
        let symbol = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: symbol), for: .normal)
        closeButton.accessibilityLabel = "Chiudi il player"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        rotateButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: symbol), for: .normal)
        rotateButton.accessibilityLabel = "Ruota lo schermo"
        rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
        pipButton.setImage(AVPictureInPictureController.pictureInPictureButtonStartImage, for: .normal)
        pipButton.accessibilityLabel = "Picture in Picture"
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
        routePicker.tintColor = .white
        routePicker.activeTintColor = accent
        routePicker.prioritizesVideoDevices = true
        [closeButton, rotateButton, pipButton].forEach { $0.tintColor = .white }

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitleLabel.numberOfLines = 2
        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 2
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topBar = UIStackView(arrangedSubviews: [closeButton, titleStack, rotateButton, routePicker, pipButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 6
        topBar.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(topBar)

        // centro: indietro, riproduci/pausa, avanti
        [backButton, playButton, forwardButton].forEach { $0.tintColor = .white }
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        refreshPlayIcon()
        let center = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        center.axis = .horizontal
        center.alignment = .center
        center.spacing = 46
        center.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(center)

        // in basso: tempo (o "in diretta") e la fila dei comandi
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        elapsedLabel.textColor = .white
        remainingLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        remainingLabel.setContentHuggingPriority(.required, for: .horizontal)
        slider.minimumTrackTintColor = accent
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(PlayerViewController.thumbImage(), for: .normal)
        slider.addTarget(self, action: #selector(sliderBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        [elapsedLabel, slider, remainingLabel].forEach { progressRow.addArrangedSubview($0) }
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.spacing = 10

        liveBadge.text = "IN DIRETTA"
        liveBadge.font = .systemFont(ofSize: 11, weight: .bold)
        liveBadge.textColor = .white
        liveBadge.backgroundColor = UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
        liveBadge.layer.cornerRadius = 5
        liveBadge.layer.masksToBounds = true
        liveBadge.setContentHuggingPriority(.required, for: .horizontal)
        liveBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        liveInfoLabel.font = .systemFont(ofSize: 13, weight: .regular)
        liveInfoLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        liveInfoLabel.lineBreakMode = .byTruncatingTail
        [liveBadge, liveInfoLabel].forEach { liveRow.addArrangedSubview($0) }
        liveRow.axis = .horizontal
        liveRow.alignment = .center
        liveRow.spacing = 10

        channelsItem.addTarget(self, action: #selector(showChannels), for: .touchUpInside)
        fitItem.addTarget(self, action: #selector(toggleFit), for: .touchUpInside)
        favItem.addTarget(self, action: #selector(favTapped), for: .touchUpInside)
        vlcItem.addTarget(self, action: #selector(vlcTapped), for: .touchUpInside)
        audioItem.addTarget(self, action: #selector(menuOpened), for: .menuActionTriggered)
        sleepItem.addTarget(self, action: #selector(menuOpened), for: .menuActionTriggered)
        speedItem.addTarget(self, action: #selector(menuOpened), for: .menuActionTriggered)
        multiItem.addTarget(self, action: #selector(multiTapped), for: .touchUpInside)
        numberItem.addTarget(self, action: #selector(numberTapped), for: .touchUpInside)
        skipItem.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        [channelsItem, numberItem, multiItem, skipItem, audioItem, fitItem, speedItem, sleepItem, favItem, vlcItem].forEach { actionBar.addArrangedSubview($0) }
        actionBar.axis = .horizontal
        actionBar.distribution = .fillEqually
        actionBar.alignment = .fill
        actionBar.spacing = 0

        let bottom = UIStackView(arrangedSubviews: [progressRow, liveRow, actionBar])
        bottom.axis = .vertical
        bottom.spacing = 10
        bottom.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(bottom)

        // attesa, errore, prossimo episodio, messaggi brevi (restano visibili anche senza comandi)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        buildErrorBox()
        buildNextBox()

        toastLabel.insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        toastLabel.font = .systemFont(ofSize: 14, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        toastLabel.layer.cornerRadius = 10
        toastLabel.layer.masksToBounds = true
        toastLabel.numberOfLines = 2
        toastLabel.textAlignment = .center
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toastLabel)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            topBar.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            topBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            rotateButton.widthAnchor.constraint(equalToConstant: 40),
            rotateButton.heightAnchor.constraint(equalToConstant: 44),
            routePicker.widthAnchor.constraint(equalToConstant: 40),
            routePicker.heightAnchor.constraint(equalToConstant: 44),
            pipButton.widthAnchor.constraint(equalToConstant: 40),
            pipButton.heightAnchor.constraint(equalToConstant: 44),

            topShade.topAnchor.constraint(equalTo: controls.topAnchor),
            topShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            topShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            topShade.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 48),

            center.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 56),
            backButton.heightAnchor.constraint(equalToConstant: 56),
            forwardButton.widthAnchor.constraint(equalToConstant: 56),
            forwardButton.heightAnchor.constraint(equalToConstant: 56),
            playButton.widthAnchor.constraint(equalToConstant: 76),
            playButton.heightAnchor.constraint(equalToConstant: 76),

            bottom.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -4),
            actionBar.heightAnchor.constraint(equalToConstant: 56),

            bottomShade.topAnchor.constraint(equalTo: bottom.topAnchor, constant: -56),
            bottomShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            bottomShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            bottomShade.bottomAnchor.constraint(equalTo: controls.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorBox.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorBox.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorBox.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            errorBox.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
            errorBox.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),

            nextBox.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            nextBox.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -14),
            nextBox.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            nextBox.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16),

            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 18),
            toastLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)
        ])
        let wide = errorBox.widthAnchor.constraint(equalToConstant: 360)
        wide.priority = .defaultHigh
        wide.isActive = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)
        doubleTapGesture = doubleTap
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        // il cursore del volume di sistema, fuori dallo schermo: serve per regolare il volume con il dito
        volumeView.alpha = 0.01
        view.addSubview(volumeView)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    private func buildErrorBox() {
        errorBox.layer.cornerRadius = 16
        errorBox.clipsToBounds = true
        errorBox.isHidden = true
        errorBox.translatesAutoresizingMaskIntoConstraints = false
        errorTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        errorTitle.textColor = .white
        errorTitle.numberOfLines = 0
        errorTitle.textAlignment = .center
        errorMessage.font = .systemFont(ofSize: 14)
        errorMessage.textColor = UIColor.white.withAlphaComponent(0.78)
        errorMessage.numberOfLines = 0
        errorMessage.textAlignment = .center
        PlayerViewController.style(retryButton, title: "Riprova", filled: false)
        PlayerViewController.style(errorVLCButton, title: PlayerViewController.otherButton, filled: true)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        errorVLCButton.addTarget(self, action: #selector(vlcTapped), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [retryButton, errorVLCButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [errorTitle, errorMessage, buttons])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: errorMessage)
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorBox.contentView.addSubview(stack)
        view.addSubview(errorBox)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: errorBox.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: errorBox.contentView.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: errorBox.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: errorBox.contentView.trailingAnchor, constant: -18),
            retryButton.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    private func buildNextBox() {
        nextBox.layer.cornerRadius = 14
        nextBox.clipsToBounds = true
        nextBox.isHidden = true
        nextBox.translatesAutoresizingMaskIntoConstraints = false
        nextLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nextLabel.textColor = .white
        nextLabel.numberOfLines = 3
        PlayerViewController.style(nextGo, title: "Guarda ora", filled: true)
        PlayerViewController.style(nextCancel, title: "Annulla", filled: false)
        nextGo.addTarget(self, action: #selector(nextGoTapped), for: .touchUpInside)
        nextCancel.addTarget(self, action: #selector(nextCancelTapped), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [nextGo, nextCancel])
        buttons.axis = .horizontal
        buttons.spacing = 8
        let stack = UIStackView(arrangedSubviews: [nextLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        nextBox.contentView.addSubview(stack)
        view.addSubview(nextBox)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: nextBox.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: nextBox.contentView.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: nextBox.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: nextBox.contentView.trailingAnchor, constant: -14),
            nextGo.heightAnchor.constraint(equalToConstant: 38),
            nextCancel.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    // MARK: piccoli aiuti

    private static func actionButton(_ symbol: String, _ title: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        config.imagePlacement = .top
        config.imagePadding = 5
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0)
        var attributes = AttributeContainer()
        attributes.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        config.attributedTitle = AttributedString(title, attributes: attributes)
        let button = UIButton(configuration: config, primaryAction: nil)
        button.accessibilityLabel = title
        return button
    }

    private static func setItem(_ button: UIButton, symbol: String, title: String) {
        guard var config = button.configuration else { return }
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        var attributes = AttributeContainer()
        attributes.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        config.attributedTitle = AttributedString(title, attributes: attributes)
        button.configuration = config
        button.accessibilityLabel = title
    }

    private static func style(_ button: UIButton, title: String, filled: Bool) {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.cornerStyle = .medium
        config.baseForegroundColor = filled ? .black : .white
        if filled { config.baseBackgroundColor = .white }
        var attributes = AttributeContainer()
        attributes.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        config.attributedTitle = AttributedString(title, attributes: attributes)
        button.configuration = config
    }

    private static func setTitle(_ button: UIButton, _ title: String) {
        guard var config = button.configuration else { return }
        var attributes = AttributeContainer()
        attributes.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        config.attributedTitle = AttributedString(title, attributes: attributes)
        button.configuration = config
    }

    private static func thumbImage() -> UIImage {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    #if canImport(MobileVLCKit)
    static let otherPlayer = "il player universale"
    static let otherButton = "Player universale"
    #else
    static let otherPlayer = "ad aprirlo in VLC"
    static let otherButton = "Apri in VLC"
    #endif

    /// Punto raggiunto: serve per passare al player universale senza perdere il segno.
    var playbackSeconds: Double {
        let s = player.currentTime().seconds
        return s.isFinite ? s : 0
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func color(hex: String) -> UIColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }
}

/// Elenco dei canali della categoria, con ricerca: si apre dal basso sopra il video.
final class ChannelListViewController: UITableViewController, UISearchResultsUpdating {

    private let names: [String]
    private let selected: Int
    private let onPick: (Int) -> Void
    private var rows: [Int]
    private var didScroll = false

    init(title: String, names: [String], selected: Int, onPick: @escaping (Int) -> Void) {
        self.names = names
        self.selected = selected
        self.onPick = onPick
        self.rows = Array(names.indices)
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "canale")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Cerca un canale"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didScroll && selected >= 0 && selected < rows.count {
            didScroll = true
            tableView.scrollToRow(at: IndexPath(row: selected, section: 0), at: .middle, animated: false)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let query = fold((searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces))
        rows = query.isEmpty ? Array(names.indices) : names.indices.filter { fold(names[$0]).contains(query) }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "canale", for: indexPath)
        let index = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = names[index]
        cell.contentConfiguration = content
        cell.accessoryType = index == selected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let index = rows[indexPath.row]
        let pick = onPick
        navigationItem.searchController?.isActive = false
        navigationController?.presentingViewController?.dismiss(animated: true) {
            pick(index)
        }
    }

    @objc private func closeTapped() {
        navigationItem.searchController?.isActive = false
        navigationController?.presentingViewController?.dismiss(animated: true)
    }
}

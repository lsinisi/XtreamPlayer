#if canImport(MobileVLCKit)
import UIKit
import MobileVLCKit
import MediaPlayer

/// Chi apre il player universale: riceve gli stessi eventi del player normale (tempo, fine, canale, preferito…).
protocol UniversalPlayerHost: AnyObject {
    func universal(_ player: UniversalPlayerViewController, event: String, data: [String: Any])
    func universalDidClose(_ player: UniversalPlayerViewController)
}

/// Player universale basato su VLC: legge i formati che il player dell'iPhone non apre
/// (MKV, AVI, audio Dolby AC3 e DTS, sottotitoli interni…). Niente Picture in Picture né AirPlay.
final class UniversalPlayerViewController: UIViewController, UIGestureRecognizerDelegate {

    weak var host: UniversalPlayerHost?

    // MARK: stato
    private let vlc = VLCMediaPlayer()
    private var target: URL?
    private var isLive = false
    private var isCatchup = false
    private var startAt: Double = 0
    private var didStart = false
    private var nextTitle: String?
    private var autoNext = false
    private var nextOff = false
    private var zapIndex = -1
    private var zapNames: [String] = []
    private var zapTitle = "Canali"
    private var fav: Bool?
    private var fill = false
    private var skip = false
    private var wantsFallback = false
    private var speed: Float = 1
    private var scrubbing = false
    private var closing = false
    private var retried = false
    private var failedShown = false
    private var lastTime: Double = -1
    private var lastMove = Date()
    private var lastEvent = Date.distantPast
    private var loadCount = 0
    private var controlsVisible = true
    private var hideTimer: Timer?
    private var pollTimer: Timer?
    private var nextTimer: Timer?
    private var accent = UIColor.systemBlue

    // MARK: viste
    private let videoHolder = UIView()
    private let videoView = UIView()
    private let controls = UIView()
    private let topShade = UIView()
    private let bottomShade = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let liveLabel = UILabel()
    private let actions = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let toastLabel = PaddedLabel()
    private let errorBox = UIView()
    private let errorTitle = UILabel()
    private let errorMessage = UILabel()
    private let badge = UILabel()

    private lazy var channelsItem = pill("Canali", "list.bullet")
    private lazy var tracksItem = pill("Audio e sottotitoli", "captions.bubble")
    private lazy var speedItem = pill("Velocità", "speedometer")
    private lazy var fitItem = pill("Riempi", "arrow.up.left.and.arrow.down.right")
    private lazy var skipItem = pill("Salta 90 s", "forward.end")
    private lazy var favItem = pill("Preferito", "star")
    private lazy var nextItem = pill("Prossimo episodio", "forward.fill")

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { return !controlsVisible }
    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { return !controlsVisible }

    deinit {
        pollTimer?.invalidate()
        hideTimer?.invalidate()
        nextTimer?.invalidate()
    }

    // MARK: comandi dalla pagina

    /// Apre un video. I campi sono gli stessi del player normale.
    func load(_ body: [String: Any]) {
        loadViewIfNeeded()
        loadCount += 1
        nextTimer?.invalidate()
        let link = (body["url"] as? String) ?? ""
        target = link.hasPrefix("/") ? URL(fileURLWithPath: link) : URL(string: link)
        isLive = (body["live"] as? Bool) ?? false
        isCatchup = (body["catchup"] as? Bool) ?? false
        startAt = (body["start"] as? Double) ?? Double((body["start"] as? Int) ?? 0)
        autoNext = (body["autonext"] as? Bool) ?? false
        nextTitle = (body["next"] as? [String: Any])?["title"] as? String
        nextOff = false
        fav = body["fav"] as? Bool
        fill = (body["fill"] as? Bool) ?? false
        skip = (body["skip"] as? Bool) ?? false
        wantsFallback = (body["fallback"] as? Bool) ?? false
        if let hex = body["accent"] as? String, let color = UniversalPlayerViewController.color(hex) { accent = color }
        if let zap = body["zap"] as? [String: Any], let list = zap["list"] as? [[String: Any]] {
            zapIndex = (zap["i"] as? Int) ?? -1
            zapTitle = (zap["name"] as? String) ?? "Canali"
            zapNames = list.map { row in
                let name = (row["name"] as? String) ?? ""
                if let n = row["num"] as? Int { return "\(n)  \(name)" }
                if let n = row["num"] as? String, !n.isEmpty { return n + "  " + name }
                return name
            }
        } else {
            zapIndex = -1
            zapNames = []
        }
        titleLabel.text = (body["title"] as? String) ?? ""
        subLabel.text = (body["sub"] as? String) ?? ""
        speed = 1
        retried = false
        configureForContent()
        startPlayback()
        showControls()
    }

    func update(_ body: [String: Any]) {
        if let sub = body["sub"] as? String { subLabel.text = sub }
        if let value = body["fav"] as? Bool { fav = value; paintFav() }
        if let toast = body["toast"] as? String { showToast(toast) }
    }

    /// Chiude il player e manda alla pagina il punto raggiunto.
    func close(notify: Bool = true) {
        guard !closing else { return }
        closing = true
        pollTimer?.invalidate()
        hideTimer?.invalidate()
        nextTimer?.invalidate()
        let (t, d) = times()
        vlc.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if notify {
            host?.universal(self, event: "closed", data: (!isLive && d > 0) ? ["t": t, "d": d] : [:])
        }
        host?.universalDidClose(self)
    }

    /// Punto raggiunto, per passare da un player all'altro senza perdere il segno.
    var playbackSeconds: Double { return times().0 }

    // MARK: riproduzione

    private func startPlayback() {
        guard let url = target else {
            showError("Indirizzo non valido", "Non riesco ad aprire questo contenuto.")
            return
        }
        closing = false
        failedShown = false
        didStart = false
        errorBox.isHidden = true
        spinner.startAnimating()
        lastTime = -1
        lastMove = Date()
        let media = VLCMedia(url: url)
        // un po' di scorta di dati: le dirette IPTV arrivano a singhiozzo
        media.addOption(isLive ? ":network-caching=2500" : ":network-caching=1500")
        media.addOption(":http-reconnect")
        if isLive { media.addOption(":http-continuous") }
        vlc.drawable = videoView
        vlc.media = media
        vlc.play()
        if speed != 1 { vlc.rate = speed }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        updateNowPlaying()
    }

    private func times() -> (Double, Double) {
        let now: VLCTime? = vlc.time
        let length: VLCTime? = vlc.media?.length
        let t = Double(now?.intValue ?? 0) / 1000
        let d = Double(length?.intValue ?? 0) / 1000
        return (max(0, t), max(0, d))
    }

    /// Ogni mezzo secondo: stato, tempo, barra, protezione contro i blocchi.
    private func poll() {
        guard !closing else { return }
        let state = vlc.state
        let (t, d) = times()
        if state == .error {
            failed()
            return
        }
        if state == .ended {
            pollTimer?.invalidate()
            reachedEnd()
            return
        }
        let playing = vlc.isPlaying
        if playing && t != lastTime {
            if lastTime >= 0 || t > 0 {
                if !didStart { started() }
            }
            lastTime = t
            lastMove = Date()
            spinner.stopAnimating()
        } else if playing && state == .buffering {
            spinner.startAnimating()
        }
        // fermo da troppo tempo: un nuovo tentativo, poi l'errore
        let stuck = Date().timeIntervalSince(lastMove)
        if !failedShown && (playing || state == .opening || state == .buffering) && stuck > (didStart ? 15 : 25) {
            failed()
            return
        }
        playButton.setImage(symbol(playing ? "pause.fill" : "play.fill", 30), for: .normal)
        if !isLive && !isCatchup && d > 0 && !scrubbing {
            slider.value = Float(t / d)
            elapsedLabel.text = UniversalPlayerViewController.format(t)
            remainingLabel.text = "-" + UniversalPlayerViewController.format(max(0, d - t))
        }
        if !isLive && d > 0 && Date().timeIntervalSince(lastEvent) >= 1 {
            lastEvent = Date()
            host?.universal(self, event: "time", data: ["t": t, "d": d])
        }
        // titoli di coda: propone il prossimo episodio
        if nextTitle != nil && !nextOff && d > 300 && d - t < 60 { nextItem.isHidden = false }
        if fill { applyFill() }
    }

    private func started() {
        didStart = true
        spinner.stopAnimating()
        if startAt > 1 {
            let (_, d) = times()
            if d > 0 {
                vlc.position = Float(min(0.99, startAt / d))
                showToast("Ripreso da " + UniversalPlayerViewController.format(startAt))
            }
            startAt = 0
        }
        if fill { applyFill() }
        scheduleHide()
        updateNowPlaying()
    }

    private func failed() {
        if !retried {
            // un secondo tentativo automatico
            retried = true
            vlc.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, !self.closing else { return }
                self.startPlayback()
            }
            return
        }
        pollTimer?.invalidate()
        failedShown = true
        vlc.stop()
        spinner.stopAnimating()
        if isLive && wantsFallback {
            let attempt = loadCount
            host?.universal(self, event: "fail", data: [:])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, !self.closing, self.loadCount == attempt else { return }
                self.showError("Il canale non risponde", "Potrebbe essere offline in questo momento e non ho trovato un canale alternativo. Riprova tra poco.")
            }
            return
        }
        showError(isLive ? "Il canale non risponde" : "Il contenuto non parte",
                  "Il server non lo sta inviando, oppure hai raggiunto il numero massimo di connessioni del tuo abbonamento. Riprova tra poco.")
    }

    private func reachedEnd() {
        guard !isLive else { return }
        host?.universal(self, event: "ended", data: [:])
        guard nextTitle != nil, !nextOff else { return }
        nextItem.isHidden = false
        showControls()
        guard autoNext else { return }
        var left = 6
        showToast("Prossimo episodio tra \(left) secondi")
        nextTimer?.invalidate()
        nextTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            left -= 1
            if left <= 0 {
                timer.invalidate()
                self.nextTapped()
            } else {
                self.showToast("Prossimo episodio tra \(left) second" + (left == 1 ? "o" : "i"))
            }
        }
    }

    private func seek(to seconds: Double) {
        let (_, d) = times()
        guard d > 0 else { return }
        vlc.position = Float(min(0.995, max(0, seconds / d)))
        lastMove = Date()
    }

    private func seek(by delta: Double) {
        guard !isLive && !isCatchup else { return }
        let (t, _) = times()
        seek(to: t + delta)
        showToast(delta > 0 ? "Avanti di \(Int(delta)) secondi" : "Indietro di \(Int(-delta)) secondi")
    }

    /// Riempie lo schermo tagliando i bordi: ingrandisce la vista del video.
    private func applyFill() {
        let size = vlc.videoSize
        let bounds = videoHolder.bounds.size
        guard fill, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            videoView.transform = .identity
            return
        }
        let videoRatio = size.width / size.height
        let viewRatio = bounds.width / bounds.height
        let k = max(videoRatio / viewRatio, viewRatio / videoRatio)
        videoView.transform = CGAffineTransform(scaleX: k, y: k)
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [MPMediaItemPropertyTitle: titleLabel.text ?? ""]
        if let sub = subLabel.text, !sub.isEmpty { info[MPMediaItemPropertyArtist] = sub }
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: pulsanti

    @objc private func closeTapped() { close() }

    @objc private func playTapped() {
        if vlc.isPlaying { vlc.pause() } else { vlc.play() }
        lastMove = Date()
        scheduleHide()
    }

    @objc private func backTapped() {
        if isLive { zap(-1) } else { seek(by: -10) }
        scheduleHide()
    }

    @objc private func forwardTapped() {
        if isLive { zap(1) } else { seek(by: 10) }
        scheduleHide()
    }

    private func zap(_ step: Int) {
        guard isLive, !zapNames.isEmpty else { return }
        let n = zapNames.count
        host?.universal(self, event: "zap", data: ["i": ((max(0, zapIndex) + step) % n + n) % n])
    }

    @objc private func channelsTapped() {
        guard !zapNames.isEmpty else { return }
        let list = ChannelListViewController(title: zapTitle, names: zapNames, selected: zapIndex) { [weak self] index in
            guard let self = self else { return }
            self.host?.universal(self, event: "zap", data: ["i": index])
        }
        let nav = UINavigationController(rootViewController: list)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    @objc private func fitTapped() {
        fill.toggle()
        applyFill()
        fitItem.configuration?.baseBackgroundColor = fill ? accent : UIColor(white: 1, alpha: 0.14)
        host?.universal(self, event: "fit", data: ["fill": fill])
        scheduleHide()
    }

    @objc private func skipTapped() {
        seek(by: 90)
        scheduleHide()
    }

    @objc private func favTapped() {
        host?.universal(self, event: "fav", data: [:])
    }

    @objc private func nextTapped() {
        nextTimer?.invalidate()
        nextItem.isHidden = true
        host?.universal(self, event: "next", data: [:])
    }

    @objc private func retryTapped() {
        retried = false
        startPlayback()
    }

    @objc private func sliderDown() {
        scrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func sliderMoved() {
        let (_, d) = times()
        guard d > 0 else { return }
        let t = Double(slider.value) * d
        elapsedLabel.text = UniversalPlayerViewController.format(t)
        remainingLabel.text = "-" + UniversalPlayerViewController.format(max(0, d - t))
    }

    @objc private func sliderUp() {
        let (_, d) = times()
        if d > 0 { seek(to: Double(slider.value) * d) }
        scrubbing = false
        scheduleHide()
    }

    // menu delle tracce: audio e sottotitoli che ci sono dentro il file
    private func trackMenuItems() -> [UIMenuElement] {
        func list(_ names: [Any], _ indexes: [Any], current: Int32, pick: @escaping (Int32) -> Void) -> [UIAction] {
            var out: [UIAction] = []
            for (i, raw) in indexes.enumerated() {
                guard let number = raw as? NSNumber else { continue }
                let value = number.int32Value
                var name = i < names.count ? "\(names[i])" : "Traccia \(i + 1)"
                if value < 0 || name == "Disable" { name = "Nessuno" }
                out.append(UIAction(title: name, state: value == current ? .on : .off) { _ in pick(value) })
            }
            return out
        }
        let audio = list(vlc.audioTrackNames, vlc.audioTrackIndexes, current: vlc.currentAudioTrackIndex) { [weak self] v in
            self?.vlc.currentAudioTrackIndex = v
        }
        let subs = list(vlc.videoSubTitlesNames, vlc.videoSubTitlesIndexes, current: vlc.currentVideoSubTitleIndex) { [weak self] v in
            self?.vlc.currentVideoSubTitleIndex = v
        }
        var menus: [UIMenuElement] = []
        if !audio.isEmpty { menus.append(UIMenu(title: "Audio", options: .displayInline, children: audio)) }
        if !subs.isEmpty { menus.append(UIMenu(title: "Sottotitoli", options: .displayInline, children: subs)) }
        if menus.isEmpty { menus.append(UIAction(title: "Nessuna traccia da scegliere", attributes: .disabled) { _ in }) }
        return menus
    }

    private func speedMenuItems() -> [UIMenuElement] {
        let values: [(Float, String)] = [(0.5, "0,5x"), (0.75, "0,75x"), (1, "Normale"), (1.25, "1,25x"), (1.5, "1,5x"), (2, "2x")]
        return values.map { value, label in
            UIAction(title: label, state: value == speed ? .on : .off) { [weak self] _ in
                guard let self = self else { return }
                self.speed = value
                self.vlc.rate = value
                self.speedItem.configuration?.title = value == 1 ? "Velocità" : label
            }
        }
    }

    // MARK: comandi a schermo

    @objc private func screenTapped() {
        if controlsVisible { hideControls() } else { showControls() }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard !isLive && !isCatchup else { return }
        let x = gesture.location(in: view).x
        seek(by: x < view.bounds.width / 2 ? -10 : 10)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // i tocchi sui pulsanti restano ai pulsanti
        var v: UIView? = touch.view
        while let current = v {
            if current is UIControl { return false }
            v = current.superview
        }
        return true
    }

    private func showControls() {
        controlsVisible = true
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        scheduleHide()
    }

    private func hideControls() {
        guard errorBox.isHidden, !scrubbing else { return }
        controlsVisible = false
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 0 }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self = self, self.vlc.isPlaying, self.presentedViewController == nil else { return }
            self.hideControls()
        }
    }

    private func showToast(_ text: String) {
        toastLabel.text = text
        toastLabel.alpha = 1
        toastLabel.isHidden = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fadeToast), object: nil)
        perform(#selector(fadeToast), with: nil, afterDelay: 2.2)
    }

    @objc private func fadeToast() {
        UIView.animate(withDuration: 0.3) { self.toastLabel.alpha = 0 }
    }

    private func showError(_ title: String, _ message: String) {
        errorTitle.text = title
        errorMessage.text = message
        errorBox.isHidden = false
        showControls()
    }

    private func paintFav() {
        favItem.isHidden = fav == nil
        let on = fav ?? false
        favItem.configuration?.title = on ? "Nei preferiti" : "Preferito"
        favItem.configuration?.image = symbol(on ? "star.fill" : "star", 13)
        favItem.configuration?.baseBackgroundColor = on ? accent : UIColor(white: 1, alpha: 0.14)
    }

    private func configureForContent() {
        let flow = isLive || isCatchup
        slider.isHidden = flow
        elapsedLabel.isHidden = flow
        remainingLabel.isHidden = flow
        liveLabel.isHidden = !flow
        liveLabel.text = isCatchup ? "  DALL'ARCHIVIO" : "  IN DIRETTA"
        backButton.setImage(symbol(isLive ? "chevron.up" : "gobackward.10", 26), for: .normal)
        forwardButton.setImage(symbol(isLive ? "chevron.down" : "goforward.10", 26), for: .normal)
        backButton.isHidden = (isLive && zapNames.isEmpty) || isCatchup
        forwardButton.isHidden = (isLive && zapNames.isEmpty) || isCatchup
        channelsItem.isHidden = zapNames.isEmpty
        speedItem.isHidden = flow
        speedItem.configuration?.title = "Velocità"
        skipItem.isHidden = !skip
        nextItem.isHidden = true
        fitItem.configuration?.baseBackgroundColor = fill ? accent : UIColor(white: 1, alpha: 0.14)
        videoView.transform = .identity
        slider.minimumTrackTintColor = accent
        paintFav()
    }

    // MARK: costruzione

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoHolder.clipsToBounds = true
        videoHolder.backgroundColor = .black
        videoView.backgroundColor = .black
        add(videoHolder, to: view)
        NSLayoutConstraint.activate([
            videoHolder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoHolder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoHolder.topAnchor.constraint(equalTo: view.topAnchor),
            videoHolder.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        add(videoView, to: videoHolder)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: videoHolder.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: videoHolder.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: videoHolder.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: videoHolder.bottomAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(screenTapped))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        tap.delegate = self
        doubleTap.delegate = self
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        add(spinner, to: view)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        add(controls, to: view)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        buildTop()
        buildCenter()
        buildBottom()
        buildToastAndError()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (topShade.layer.sublayers?.first as? CAGradientLayer)?.frame = topShade.bounds
        (bottomShade.layer.sublayers?.first as? CAGradientLayer)?.frame = bottomShade.bounds
        applyFill()
    }

    private func buildTop() {
        shade(topShade, top: true)
        add(topShade, to: controls)
        NSLayoutConstraint.activate([
            topShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            topShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            topShade.topAnchor.constraint(equalTo: controls.topAnchor),
            topShade.heightAnchor.constraint(equalToConstant: 150)
        ])
        round(closeButton, "xmark", 17)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "Chiudi"
        closeButton.layer.cornerRadius = 21

        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .white
        subLabel.font = .systemFont(ofSize: 13.5)
        subLabel.textColor = UIColor(white: 1, alpha: 0.75)
        badge.text = "  PLAYER UNIVERSALE  "
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = UIColor(white: 1, alpha: 0.85)
        badge.backgroundColor = UIColor(white: 1, alpha: 0.16)
        badge.layer.cornerRadius = 5
        badge.clipsToBounds = true
        let texts = UIStackView(arrangedSubviews: [titleLabel, subLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [closeButton, texts, badge])
        row.alignment = .center
        row.spacing = 12
        add(row, to: controls)
        let g = controls.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 42),
            closeButton.heightAnchor.constraint(equalToConstant: 42),
            row.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: g.topAnchor, constant: 8)
        ])
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func buildCenter() {
        round(backButton, "gobackward.10", 26)
        round(forwardButton, "goforward.10", 26)
        playButton.setImage(symbol("pause.fill", 30), for: .normal)
        playButton.tintColor = .black
        playButton.backgroundColor = .white
        playButton.layer.cornerRadius = 36
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        backButton.accessibilityLabel = "Indietro"
        forwardButton.accessibilityLabel = "Avanti"
        playButton.accessibilityLabel = "Pausa o riprendi"
        let row = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        row.alignment = .center
        row.spacing = 40
        add(row, to: controls)
        NSLayoutConstraint.activate([
            backButton.widthAnchor.constraint(equalToConstant: 56),
            backButton.heightAnchor.constraint(equalToConstant: 56),
            forwardButton.widthAnchor.constraint(equalToConstant: 56),
            forwardButton.heightAnchor.constraint(equalToConstant: 56),
            playButton.widthAnchor.constraint(equalToConstant: 72),
            playButton.heightAnchor.constraint(equalToConstant: 72),
            row.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: controls.centerYAnchor)
        ])
    }

    private func buildBottom() {
        shade(bottomShade, top: false)
        add(bottomShade, to: controls)
        NSLayoutConstraint.activate([
            bottomShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            bottomShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            bottomShade.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            bottomShade.heightAnchor.constraint(equalToConstant: 210)
        ])
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.text = "0:00"
        }
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.3)
        slider.setThumbImage(UniversalPlayerViewController.thumb(), for: .normal)
        slider.addTarget(self, action: #selector(sliderDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        liveLabel.font = .systemFont(ofSize: 12, weight: .bold)
        liveLabel.textColor = .white
        liveLabel.text = "  IN DIRETTA"
        let dot = UIView()
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4
        add(dot, to: liveLabel)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: liveLabel.leadingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: liveLabel.centerYAnchor)
        ])
        let seekRow = UIStackView(arrangedSubviews: [elapsedLabel, slider, remainingLabel, liveLabel])
        seekRow.alignment = .center
        seekRow.spacing = 10

        channelsItem.addTarget(self, action: #selector(channelsTapped), for: .touchUpInside)
        fitItem.addTarget(self, action: #selector(fitTapped), for: .touchUpInside)
        skipItem.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        favItem.addTarget(self, action: #selector(favTapped), for: .touchUpInside)
        nextItem.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        tracksItem.showsMenuAsPrimaryAction = true
        tracksItem.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.trackMenuItems() ?? []) }])
        speedItem.showsMenuAsPrimaryAction = true
        speedItem.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.speedMenuItems() ?? []) }])
        for item in [tracksItem, speedItem] {
            item.addTarget(self, action: #selector(menuOpened), for: .menuActionTriggered)
        }
        for item in [nextItem, skipItem, channelsItem, tracksItem, speedItem, fitItem, favItem] { actions.addArrangedSubview(item) }
        actions.spacing = 8
        actions.alignment = .center
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        add(actions, to: scroller)

        let column = UIStackView(arrangedSubviews: [seekRow, scroller])
        column.axis = .vertical
        column.spacing = 12
        add(column, to: controls)
        let g = controls.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -10),
            seekRow.heightAnchor.constraint(equalToConstant: 30),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            remainingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            scroller.heightAnchor.constraint(equalToConstant: 40),
            actions.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            actions.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            actions.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            actions.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
        ])
    }

    @objc private func menuOpened() {
        hideTimer?.invalidate()
    }

    private func buildToastAndError() {
        toastLabel.insets = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        toastLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor(white: 0.1, alpha: 0.9)
        toastLabel.layer.cornerRadius = 12
        toastLabel.clipsToBounds = true
        toastLabel.isHidden = true
        toastLabel.numberOfLines = 2
        toastLabel.textAlignment = .center
        add(toastLabel, to: view)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 70),
            toastLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.86)
        ])

        errorBox.backgroundColor = UIColor(white: 0.1, alpha: 0.96)
        errorBox.layer.cornerRadius = 20
        errorBox.isHidden = true
        errorTitle.font = .systemFont(ofSize: 18, weight: .bold)
        errorTitle.textColor = .white
        errorTitle.textAlignment = .center
        errorTitle.numberOfLines = 0
        errorMessage.font = .systemFont(ofSize: 14)
        errorMessage.textColor = UIColor(white: 1, alpha: 0.75)
        errorMessage.textAlignment = .center
        errorMessage.numberOfLines = 0
        var retry = UIButton.Configuration.filled()
        retry.title = "Riprova"
        retry.baseBackgroundColor = .white
        retry.baseForegroundColor = .black
        retry.cornerStyle = .capsule
        let retryButton = UIButton(configuration: retry)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        var closeConf = UIButton.Configuration.filled()
        closeConf.title = "Chiudi"
        closeConf.baseBackgroundColor = UIColor(white: 1, alpha: 0.16)
        closeConf.baseForegroundColor = .white
        closeConf.cornerStyle = .capsule
        let closeErr = UIButton(configuration: closeConf)
        closeErr.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [retryButton, closeErr])
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [errorTitle, errorMessage, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(18, after: errorMessage)
        add(stack, to: errorBox)
        add(errorBox, to: view)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: errorBox.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: errorBox.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: errorBox.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: errorBox.bottomAnchor, constant: -20),
            buttons.heightAnchor.constraint(equalToConstant: 44),
            errorBox.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorBox.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorBox.widthAnchor.constraint(equalToConstant: 320)
        ])
    }

    // MARK: piccoli aiuti

    private func add(_ child: UIView, to parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
    }

    private func symbol(_ name: String, _ size: CGFloat) -> UIImage? {
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    private func round(_ button: UIButton, _ name: String, _ size: CGFloat) {
        button.setImage(symbol(name, size), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(white: 1, alpha: 0.14)
        button.layer.cornerRadius = 28
    }

    private func pill(_ title: String, _ name: String) -> UIButton {
        var c = UIButton.Configuration.filled()
        c.title = title
        c.image = symbol(name, 13)
        c.imagePadding = 6
        c.baseBackgroundColor = UIColor(white: 1, alpha: 0.14)
        c.baseForegroundColor = .white
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 13, bottom: 8, trailing: 13)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            return out
        }
        return UIButton(configuration: c)
    }

    private func shade(_ v: UIView, top: Bool) {
        let g = CAGradientLayer()
        g.colors = top ? [UIColor(white: 0, alpha: 0.75).cgColor, UIColor.clear.cgColor]
                       : [UIColor.clear.cgColor, UIColor(white: 0, alpha: 0.85).cgColor]
        v.layer.addSublayer(g)
        v.isUserInteractionEnabled = false
    }

    private static func thumb() -> UIImage {
        let size = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, x = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
    }

    static func color(_ hex: String) -> UIColor? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
#endif

import UIKit
import AVFoundation

/// Chi ospita il multischermo (la schermata principale).
protocol MultiHost: AnyObject {
    func multiDidClose(_ multi: MultiViewController, ids: [String])
    func multiWantsFullScreen(_ multi: MultiViewController, id: String, ids: [String])
}

/// Un canale che si può mettere in un riquadro.
struct MultiChannel {
    let id: String
    let name: String
    let num: String
    var label: String { return num.isEmpty ? name : num + "   " + name }
}

/// Un riquadro del multischermo: il suo video, il nome del canale e l'indicatore dell'audio.
final class MultiTile: UIView {

    private(set) var channel: MultiChannel
    let player = AVPlayer()
    private let video = PlayerVideoView()
    private let nameLabel = PaddedLabel()
    private let audioIcon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var failObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var url: URL?
    private var retried = false

    var accent = UIColor.white { didSet { refreshAudio() } }
    var hasAudio = false { didSet { refreshAudio() } }

    init(channel: MultiChannel) {
        self.channel = channel
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        layer.cornerRadius = 10
        layer.masksToBounds = true
        layer.borderWidth = 2

        video.translatesAutoresizingMaskIntoConstraints = false
        video.playerLayer.player = player
        video.playerLayer.videoGravity = .resizeAspect
        video.isUserInteractionEnabled = false
        addSubview(video)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        nameLabel.layer.cornerRadius = 6
        nameLabel.layer.masksToBounds = true
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        audioIcon.contentMode = .center
        audioIcon.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        audioIcon.layer.cornerRadius = 13
        audioIcon.layer.masksToBounds = true
        audioIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(audioIcon)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            video.topAnchor.constraint(equalTo: topAnchor),
            video.bottomAnchor.constraint(equalTo: bottomAnchor),
            video.leadingAnchor.constraint(equalTo: leadingAnchor),
            video.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            audioIcon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            audioIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            audioIcon.widthAnchor.constraint(equalToConstant: 26),
            audioIcon.heightAnchor.constraint(equalToConstant: 26),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])

        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        player.isMuted = true
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.playbackStateChanged() }
        }
        nameLabel.text = channel.name
        refreshAudio()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }

    deinit {
        if let observer = failObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// Mette un canale nel riquadro e lo fa partire.
    func play(_ channel: MultiChannel, url: URL) {
        self.channel = channel
        self.url = url
        nameLabel.text = channel.name
        retried = false
        start()
    }

    /// Riparte dal momento attuale della diretta (dopo una pausa o al ritorno nell'app).
    func restart() {
        retried = false
        start()
    }

    func stop() {
        watchdog?.invalidate()
        clearObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func start() {
        guard let target = url else { return }
        clearObservers()
        messageLabel.isHidden = true
        spinner.startAnimating()
        let item = AVPlayerItem(url: target)
        item.preferredForwardBufferDuration = 6
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self = self, observed === self.player.currentItem else { return }
                if observed.status == .failed { self.failed() }
            }
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.failed()
        }
        player.replaceCurrentItem(with: item)
        player.play()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 18, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.player.timeControlStatus != .playing && self.player.currentTime().seconds < 0.5 { self.failed() }
        }
    }

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let observer = failObserver { NotificationCenter.default.removeObserver(observer) }
        failObserver = nil
    }

    private func failed() {
        watchdog?.invalidate()
        let status = player.currentItem?.errorLog()?.events.last?.errorStatusCode ?? 0
        let refused = [401, 403, 429, 458, 509].contains(status)
        if !retried && !refused {
            retried = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.url != nil, self.superview != nil else { return }
                self.start()
            }
            return
        }
        spinner.stopAnimating()
        messageLabel.text = refused
            ? "Il server non accetta altre connessioni: il tuo abbonamento non permette di vedere tanti canali insieme."
            : "Questo canale non risponde. Toccalo e scegli Cambia per metterne un altro."
        messageLabel.isHidden = false
    }

    private func playbackStateChanged() {
        switch player.timeControlStatus {
        case .playing:
            spinner.stopAnimating()
            watchdog?.invalidate()
            messageLabel.isHidden = true
        case .waitingToPlayAtSpecifiedRate:
            if messageLabel.isHidden { spinner.startAnimating() }
        default:
            break
        }
    }

    private func refreshAudio() {
        player.isMuted = !hasAudio
        layer.borderColor = (hasAudio ? accent : UIColor.clear).cgColor
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        audioIcon.image = UIImage(systemName: hasAudio ? "speaker.wave.2.fill" : "speaker.slash.fill", withConfiguration: config)
        audioIcon.tintColor = hasAudio ? accent : UIColor.white.withAlphaComponent(0.7)
    }
}

/// Multischermo: fino a quattro canali insieme. Si sente l'audio del riquadro selezionato (quello con il bordo).
/// In basso i comandi: aggiungi, cambia, togli, schermo intero.
final class MultiViewController: UIViewController {

    weak var host: MultiHost?

    private var tiles: [MultiTile] = []
    private var pool: [MultiChannel] = []
    private var prefix = ""
    private var suffix = ""
    private var maxTiles = 4
    private var selected = 0
    private var accent = UIColor(red: 0.31, green: 0.48, blue: 1.0, alpha: 1)
    private var forcedMask: UIInterfaceOrientationMask?
    private var closed = false
    private var observers: [NSObjectProtocol] = []

    private let grid = UIView()
    private let closeButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let actionBar = UIStackView()
    private let addItem = MultiViewController.actionButton("plus.rectangle.on.rectangle", "Aggiungi")
    private let changeItem = MultiViewController.actionButton("arrow.left.arrow.right", "Cambia")
    private let removeItem = MultiViewController.actionButton("xmark.rectangle", "Togli")
    private let fullItem = MultiViewController.actionButton("arrow.up.left.and.arrow.down.right", "Schermo intero")

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return forcedMask ?? .allButUpsideDown
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        buildInterface()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tiles.forEach { $0.player.pause() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tiles.forEach { $0.restart() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTiles()
    }

    // MARK: comandi dalla pagina

    func load(_ body: [String: Any]) {
        loadViewIfNeeded()
        prefix = (body["prefix"] as? String) ?? ""
        suffix = (body["suffix"] as? String) ?? ""
        maxTiles = min(4, max(1, (body["max"] as? NSNumber)?.intValue ?? 4))
        if let hex = body["accent"] as? String, let color = PlayerViewController.color(hex: hex) { accent = color }
        pool = MultiViewController.channels(body["pool"])
        tiles.forEach { $0.stop(); $0.removeFromSuperview() }
        tiles = []
        for channel in MultiViewController.channels(body["items"]).prefix(maxTiles) {
            addTile(channel)
        }
        select(0)
        refreshActions()
    }

    private static func channels(_ value: Any?) -> [MultiChannel] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return MultiChannel(id: id, name: (item["name"] as? String) ?? "Canale", num: (item["num"] as? String) ?? "")
        }
    }

    private func streamURL(_ channel: MultiChannel) -> URL? {
        return URL(string: prefix + channel.id + suffix)
    }

    // MARK: riquadri

    private func addTile(_ channel: MultiChannel) {
        guard tiles.count < maxTiles, let url = streamURL(channel) else { return }
        let tile = MultiTile(channel: channel)
        tile.accent = accent
        tile.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tileTapped(_:))))
        grid.addSubview(tile)
        tiles.append(tile)
        tile.play(channel, url: url)
        view.setNeedsLayout()
    }

    private func select(_ index: Int) {
        guard !tiles.isEmpty else { return }
        selected = min(max(0, index), tiles.count - 1)
        for (i, tile) in tiles.enumerated() { tile.hasAudio = i == selected }
    }

    private func layoutTiles() {
        let area = grid.bounds
        let count = tiles.count
        guard count > 0, area.width > 0, area.height > 0 else { return }
        let landscape = area.width > area.height
        let columns = landscape ? (count == 1 ? 1 : 2) : (count <= 3 ? 1 : 2)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let gap: CGFloat = 6
        let cellWidth = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        // ogni riquadro resta in 16:9 dentro la sua cella
        var tileWidth = cellWidth
        var tileHeight = tileWidth * 9 / 16
        if tileHeight > cellHeight {
            tileHeight = cellHeight
            tileWidth = tileHeight * 16 / 9
        }
        let usedHeight = tileHeight * CGFloat(rows) + gap * CGFloat(rows - 1)
        let top = max(0, (area.height - usedHeight) / 2)
        for (i, tile) in tiles.enumerated() {
            let row = i / columns, column = i % columns
            let inRow = min(columns, count - row * columns)
            let rowWidth = tileWidth * CGFloat(inRow) + gap * CGFloat(inRow - 1)
            let left = (area.width - rowWidth) / 2
            tile.frame = CGRect(x: left + CGFloat(column) * (tileWidth + gap),
                                y: top + CGFloat(row) * (tileHeight + gap),
                                width: tileWidth, height: tileHeight)
        }
    }

    private func animateLayout() {
        UIView.animate(withDuration: 0.25) { self.layoutTiles() }
    }

    private func refreshActions() {
        let canAdd = tiles.count < maxTiles && !pool.isEmpty
        addItem.isEnabled = canAdd
        addItem.alpha = canAdd ? 1 : 0.35
        changeItem.isEnabled = !pool.isEmpty
        changeItem.alpha = pool.isEmpty ? 0.35 : 1
        hintLabel.text = tiles.count > 1 ? "Tocca un canale per sentire il suo audio" : "Tocca Aggiungi per affiancare un altro canale"
    }

    private var ids: [String] { return tiles.map { $0.channel.id } }

    // MARK: azioni

    @objc private func tileTapped(_ gesture: UITapGestureRecognizer) {
        guard let tile = gesture.view as? MultiTile, let index = tiles.firstIndex(where: { $0 === tile }) else { return }
        select(index)
    }

    @objc private func addTapped() {
        guard tiles.count < maxTiles else { return }
        pick(title: "Aggiungi un canale") { [weak self] channel in
            guard let self = self else { return }
            self.addTile(channel)
            self.select(self.tiles.count - 1)
            self.refreshActions()
            self.animateLayout()
        }
    }

    @objc private func changeTapped() {
        guard selected < tiles.count else { return }
        pick(title: "Cambia canale") { [weak self] channel in
            guard let self = self, self.selected < self.tiles.count, let url = self.streamURL(channel) else { return }
            self.tiles[self.selected].play(channel, url: url)
        }
    }

    @objc private func removeTapped() {
        guard selected < tiles.count else { return }
        let tile = tiles.remove(at: selected)
        tile.stop()
        tile.removeFromSuperview()
        if tiles.isEmpty {
            close()
            return
        }
        select(min(selected, tiles.count - 1))
        refreshActions()
        animateLayout()
    }

    @objc private func fullTapped() {
        guard selected < tiles.count else { return }
        let id = tiles[selected].channel.id
        let all = ids
        stopAll()
        host?.multiWantsFullScreen(self, id: id, ids: all)
    }

    @objc private func closeTapped() { close() }

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
    }

    private func pick(title: String, done: @escaping (MultiChannel) -> Void) {
        let channels = pool
        let list = ChannelListViewController(title: title, names: channels.map { $0.label }, selected: -1) { index in
            if index >= 0 && index < channels.count { done(channels[index]) }
        }
        let nav = UINavigationController(rootViewController: list)
        nav.overrideUserInterfaceStyle = .dark
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func stopAll() {
        if closed { return }
        closed = true
        tiles.forEach { $0.stop() }
    }

    /// Chiude il multischermo e fa sapere alla pagina quali canali c'erano, per riproporli la prossima volta.
    func close() {
        let all = ids
        stopAll()
        host?.multiDidClose(self, ids: all)
    }

    // MARK: costruzione dell'interfaccia

    private func buildInterface() {
        let safe = view.safeAreaLayoutGuide
        let symbol = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: symbol), for: .normal)
        closeButton.accessibilityLabel = "Chiudi il multischermo"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        rotateButton.setImage(UIImage(systemName: "rotate.right", withConfiguration: symbol), for: .normal)
        rotateButton.accessibilityLabel = "Ruota lo schermo"
        rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
        [closeButton, rotateButton].forEach { $0.tintColor = .white }

        titleLabel.text = "Multischermo"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        hintLabel.lineBreakMode = .byTruncatingTail
        let titles = UIStackView(arrangedSubviews: [titleLabel, hintLabel])
        titles.axis = .vertical
        titles.spacing = 1
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topBar = UIStackView(arrangedSubviews: [closeButton, titles, rotateButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 6
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        addItem.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        changeItem.addTarget(self, action: #selector(changeTapped), for: .touchUpInside)
        removeItem.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        fullItem.addTarget(self, action: #selector(fullTapped), for: .touchUpInside)
        [addItem, changeItem, removeItem, fullItem].forEach { actionBar.addArrangedSubview($0) }
        actionBar.axis = .horizontal
        actionBar.distribution = .fillEqually
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: safe.topAnchor, constant: 2),
            topBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            topBar.heightAnchor.constraint(equalToConstant: 46),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            rotateButton.widthAnchor.constraint(equalToConstant: 44),
            rotateButton.heightAnchor.constraint(equalToConstant: 44),

            actionBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            actionBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            actionBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -2),
            actionBar.heightAnchor.constraint(equalToConstant: 54),

            grid.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -4),
            grid.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 6),
            grid.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -6)
        ])
    }

    private static func actionButton(_ symbol: String, _ title: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
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
}

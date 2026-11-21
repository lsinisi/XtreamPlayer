import UIKit

// Pezzi in comune tra il player dell'iPhone e il player universale:
// la scheda di anteprima dello zapping e il blocco dello schermo.

// MARK: - anteprima del canale durante lo zapping

/// Scheda che compare cambiando canale: numero e nome, logo e programma in onda.
/// Si tocca per andare subito al canale.
final class ZapCardView: UIControl {

    private static let logos = NSCache<NSString, UIImage>()

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let logoBox = UIView()
    private let logo = UIImageView()
    private let titleLabel = UILabel()
    private let nowLabel = UILabel()
    private let hintLabel = UILabel()
    private var logoLink = ""
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        alpha = 0
        isHidden = true
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        clipsToBounds = true
        accessibilityTraits = .button

        blur.isUserInteractionEnabled = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        logoBox.backgroundColor = UIColor(white: 1, alpha: 0.1)
        logoBox.layer.cornerRadius = 10
        logoBox.isUserInteractionEnabled = false
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logoBox.addSubview(logo)

        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        nowLabel.font = .systemFont(ofSize: 14, weight: .regular)
        nowLabel.textColor = UIColor(white: 1, alpha: 0.78)
        nowLabel.numberOfLines = 2
        hintLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        hintLabel.textColor = UIColor(white: 1, alpha: 0.5)
        hintLabel.text = "Tocca per andare subito"
        let texts = UIStackView(arrangedSubviews: [titleLabel, nowLabel, hintLabel])
        texts.axis = .vertical
        texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [logoBox, texts])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            logoBox.widthAnchor.constraint(equalToConstant: 72),
            logoBox.heightAnchor.constraint(equalToConstant: 50),
            logo.leadingAnchor.constraint(equalTo: logoBox.leadingAnchor, constant: 6),
            logo.trailingAnchor.constraint(equalTo: logoBox.trailingAnchor, constant: -6),
            logo.topAnchor.constraint(equalTo: logoBox.topAnchor, constant: 5),
            logo.bottomAnchor.constraint(equalTo: logoBox.bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }

    /// Mostra un canale (il programma arriva subito dopo con setNow).
    func show(title: String, logo link: String) {
        hideWork?.cancel()
        titleLabel.text = title
        nowLabel.text = "Cerco il programma in onda…"
        hintLabel.isHidden = false
        accessibilityLabel = title
        loadLogo(link)
        isHidden = false
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    }

    func setNow(_ text: String) {
        nowLabel.text = text.isEmpty ? "Programma non disponibile" : text
    }

    /// Il canale sta partendo: la scheda resta un attimo e poi sparisce.
    func committed() {
        hintLabel.isHidden = true
        hide(after: 1.6)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.25, animations: { self?.alpha = 0 }) { _ in
                if self?.alpha == 0 { self?.isHidden = true }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func loadLogo(_ link: String) {
        logoLink = link
        logo.image = nil
        guard !link.isEmpty, let url = URL(string: link) else { return }
        if let cached = ZapCardView.logos.object(forKey: link as NSString) {
            logo.image = cached
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            ZapCardView.logos.setObject(image, forKey: link as NSString)
            DispatchQueue.main.async {
                guard let self = self, self.logoLink == link else { return }
                self.logo.image = image
            }
        }.resume()
    }
}

/// Gestisce lo zapping con anteprima: ogni colpo sposta il canale in arrivo,
/// e dopo un attimo senza altri colpi (o con un tocco sulla scheda) si cambia davvero.
final class ZapPreview: NSObject {

    let card = ZapCardView()
    private(set) var pending: Int?
    private var timer: Timer?
    /// Cambia davvero canale (indice nell'elenco).
    var commit: ((Int) -> Void)?
    /// Chiede alla pagina il programma in onda per un canale.
    var peek: ((Int) -> Void)?

    override init() {
        super.init()
        card.addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    func step(_ delta: Int, from current: Int, names: [String], logos: [String]) {
        let count = names.count
        guard count > 1 else { return }
        let base = pending ?? max(0, current)
        let index = ((base + delta) % count + count) % count
        pending = index
        card.show(title: names[index], logo: index < logos.count ? logos[index] : "")
        peek?(index)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in self?.fire() }
    }

    @objc func fire() {
        timer?.invalidate()
        guard let index = pending else { return }
        pending = nil
        card.committed()
        commit?(index)
    }

    /// Il programma in onda è arrivato dalla pagina.
    func setNow(_ text: String, for index: Int) {
        if index == pending { card.setNow(text) }
    }

    /// Un nuovo canale è partito: se non ce n'è un altro in arrivo la scheda sparisce.
    func loaded() {
        if pending == nil { card.hide(after: 0.8) }
    }

    func cancel() {
        timer?.invalidate()
        pending = nil
        card.hide()
    }
}

// MARK: - blocco dello schermo

/// Velo trasparente sopra il player: con lo schermo bloccato i tocchi non fanno niente.
/// Un tocco mostra il lucchetto; tenendolo premuto si sblocca.
final class PlayerLockView: UIView {

    var onUnlock: (() -> Void)?
    private let badge = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private var fadeWork: DispatchWorkItem?

    var isLocked: Bool { return !isHidden }

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isHidden = true

        badge.layer.cornerRadius = 24
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isAccessibilityElement = true
        badge.accessibilityLabel = "Schermo bloccato. Tieni premuto per sbloccare"
        addSubview(badge)

        let icon = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)))
        icon.tintColor = .white
        let label = UILabel()
        label.text = "Tieni premuto per sbloccare"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        badge.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -28),
            badge.heightAnchor.constraint(equalToConstant: 48),
            row.leadingAnchor.constraint(equalTo: badge.contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: badge.contentView.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: badge.contentView.centerYAnchor)
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.8
        badge.addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }

    func lock() {
        isHidden = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showBadge()
    }

    func unlock() {
        guard isLocked else { return }
        fadeWork?.cancel()
        isHidden = true
        onUnlock?()
    }

    @objc private func tapped() { showBadge() }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        unlock()
    }

    private func showBadge() {
        fadeWork?.cancel()
        UIView.animate(withDuration: 0.15) { self.badge.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.badge.alpha = 0.02 }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

import Foundation

/// Scarica film ed episodi sull'iPhone per vederli senza connessione.
/// I download continuano anche se esci dall'app; i file stanno nella cartella privata dell'app.
final class DownloadManager: NSObject, URLSessionDownloadDelegate {

    static let shared = DownloadManager()

    /// Un video scaricato o in scaricamento.
    struct Item: Codable {
        var id: String
        var title: String
        var sub: String
        var img: String
        var ext: String
        var meta: String        // dati della pagina (JSON) per riprendere da dove eri rimasto
        var file: String        // nome del file nella cartella dei download
        var size: Int64
        var done: Bool
        var failed: Bool
        var added: Double
    }

    /// Chiamata (sul thread principale) ogni volta che cambia qualcosa: la schermata aggiorna l'elenco.
    var onChange: (() -> Void)?
    /// Consegnata dal sistema quando finisce i download a app chiusa.
    var backgroundCompletion: (() -> Void)?

    private var items: [String: Item] = [:]
    private var progress: [String: Double] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var lastNotify = Date.distantPast
    private let folder: URL
    private let indexFile: URL
    private var session: URLSession!

    private override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Scaricati", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        folder = dir
        indexFile = dir.appendingPathComponent("indice.json")
        super.init()
        if let data = try? Data(contentsOf: indexFile), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            for item in saved { items[item.id] = item }
        }
        let config = URLSessionConfiguration.background(withIdentifier: "it.xtream.player.scaricati")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        // ritrova i download rimasti in corso dall'ultima volta
        session.getAllTasks { [weak self] all in
            DispatchQueue.main.async {
                guard let self = self else { return }
                for task in all {
                    if let id = task.taskDescription, let download = task as? URLSessionDownloadTask { self.tasks[id] = download }
                }
                // un download che non è finito e non è più in corso è andato perso
                for (id, item) in self.items where !item.done && !item.failed && self.tasks[id] == nil {
                    self.items[id]?.failed = true
                }
                self.save()
                self.notify(force: true)
            }
        }
    }

    // MARK: comandi

    func start(id: String, url: URL, title: String, sub: String, img: String, ext: String, meta: String) {
        if let old = items[id], old.done { return }
        tasks[id]?.cancel()
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        items[id] = Item(id: id, title: title, sub: sub, img: img, ext: ext, meta: meta, file: safe + "." + ext,
                         size: 0, done: false, failed: false, added: Date().timeIntervalSince1970)
        progress[id] = 0
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        tasks[id] = task
        task.resume()
        save()
        notify(force: true)
    }

    /// Annulla un download in corso oppure elimina un video scaricato.
    func remove(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
        if let item = items[id] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(item.file))
        }
        items[id] = nil
        save()
        notify(force: true)
    }

    /// L'elenco per la pagina: stato, avanzamento e indirizzo del file per chi è pronto.
    func list() -> [[String: Any]] {
        return items.values.sorted { $0.added > $1.added }.map { item -> [String: Any] in
            var row: [String: Any] = [
                "id": item.id, "title": item.title, "sub": item.sub, "img": item.img, "ext": item.ext,
                "meta": item.meta, "size": Double(item.size),
                "state": item.done ? "done" : (item.failed ? "failed" : "loading"),
                "progress": item.done ? 1.0 : (progress[item.id] ?? 0)
            ]
            if item.done { row["path"] = folder.appendingPathComponent(item.file).absoluteString }
            return row
        }
    }

    // MARK: avanzamento e fine

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, items[id] != nil else { return }
        if totalBytesExpectedToWrite > 0 {
            progress[id] = min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
        items[id]?.size = totalBytesWritten
        notify(force: false)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, var item = items[id] else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let target = folder.appendingPathComponent(item.file)
        try? FileManager.default.removeItem(at: target)
        var ok = status >= 200 && status < 300
        if ok {
            do { try FileManager.default.moveItem(at: location, to: target) } catch { ok = false }
        }
        if ok {
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? item.size
            // un file minuscolo non è un video: di solito è la pagina d'errore del server
            if size < 200_000 {
                try? FileManager.default.removeItem(at: target)
                ok = false
            } else {
                item.size = size
            }
        }
        item.done = ok
        item.failed = !ok
        items[id] = item
        progress[id] = nil
        save()
        notify(force: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        tasks[id] = nil
        guard let failure = error, var item = items[id], !item.done else { return }
        if (failure as NSError).code == NSURLErrorCancelled { return }
        item.failed = true
        items[id] = item
        progress[id] = nil
        save()
        notify(force: true)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = backgroundCompletion
        backgroundCompletion = nil
        done?()
    }

    // MARK: salvataggio

    private func save() {
        if let data = try? JSONEncoder().encode(Array(items.values)) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    private func notify(force: Bool) {
        if !force && Date().timeIntervalSince(lastNotify) < 0.7 { return }
        lastNotify = Date()
        onChange?()
    }
}

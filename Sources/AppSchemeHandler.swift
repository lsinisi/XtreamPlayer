import Foundation
import WebKit

/// Indirizzi interni "xtream://app/...": servono i file della pagina, l'archivio delle impostazioni
/// e inoltrano le chiamate a player_api.php del server Xtream (che dalla pagina sarebbero bloccate).
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "xtream"
    private static let userAgent = "VLC/3.0.20 LibVLC/3.0.20"

    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    private let session: URLSession

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": AppSchemeHandler.userAgent]
        session = URLSession(configuration: config, delegate: TrustAllDelegate(), delegateQueue: nil)
        super.init()
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock(); active.insert(id); lock.unlock()

        guard let url = urlSchemeTask.request.url else {
            respond(urlSchemeTask, 400, "text/plain; charset=utf-8", Data())
            return
        }
        let path = url.path
        if path == "/" || path == "/index.html" {
            serveFile("index.html", "text/html; charset=utf-8", urlSchemeTask)
        } else if path.hasPrefix("/assets/") && !path.contains("..") {
            serveFile(String(path.dropFirst()), AppSchemeHandler.mimeType(path), urlSchemeTask)
        } else if path == "/favicon.ico" {
            serveFile("assets/icon.png", "image/png", urlSchemeTask)
        } else if path == "/store" {
            respond(urlSchemeTask, 200, "application/json; charset=utf-8", Data(SettingsStore.shared.json().utf8))
        } else if path == "/api" {
            handleAPI(url, urlSchemeTask)
        } else if path == "/hello" || path == "/ping" || path == "/bye" {
            respond(urlSchemeTask, 204, "text/plain", Data())
        } else {
            respond(urlSchemeTask, 404, "text/plain; charset=utf-8", Data("Non trovato".utf8))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock(); active.remove(ObjectIdentifier(urlSchemeTask as AnyObject)); lock.unlock()
    }

    private func isActive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(ObjectIdentifier(task as AnyObject))
    }

    /// Risponde alla pagina (sempre sul thread principale, e solo se la richiesta è ancora aperta).
    private func respond(_ task: WKURLSchemeTask, _ code: Int, _ type: String, _ data: Data) {
        DispatchQueue.main.async {
            guard self.isActive(task), let url = task.request.url else { return }
            let headers = [
                "Content-Type": type,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store"
            ]
            guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
            task.didReceive(response)
            if !data.isEmpty { task.didReceive(data) }
            task.didFinish()
            self.lock.lock(); self.active.remove(ObjectIdentifier(task as AnyObject)); self.lock.unlock()
        }
    }

    private func respondError(_ task: WKURLSchemeTask, _ code: Int, _ message: String) {
        let body = "{\"error\":" + SettingsStore.quote(message) + "}"
        respond(task, code, "application/json; charset=utf-8", Data(body.utf8))
    }

    // MARK: file della pagina

    private func serveFile(_ relative: String, _ type: String, _ task: WKURLSchemeTask) {
        let fileURL = Bundle.main.bundleURL.appendingPathComponent("web").appendingPathComponent(relative)
        if let data = try? Data(contentsOf: fileURL) {
            respond(task, 200, type, data)
        } else {
            respond(task, 404, "text/plain; charset=utf-8", Data("Non trovato".utf8))
        }
    }

    private static func mimeType(_ path: String) -> String {
        let p = path.lowercased()
        if p.hasSuffix(".js") { return "text/javascript; charset=utf-8" }
        if p.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if p.hasSuffix(".woff2") { return "font/woff2" }
        if p.hasSuffix(".png") { return "image/png" }
        if p.hasSuffix(".svg") { return "image/svg+xml" }
        if p.hasSuffix(".json") { return "application/json" }
        return "application/octet-stream"
    }

    // MARK: player_api.php

    private func handleAPI(_ url: URL, _ task: WKURLSchemeTask) {
        var params = AppSchemeHandler.parseQuery(url.query ?? "")
        guard let index = params.firstIndex(where: { $0.0 == "server" }) else {
            respondError(task, 400, "Indirizzo del server non valido")
            return
        }
        var server = params[index].1
        params.remove(at: index)
        params.removeAll { $0.0 == "tok" }   // parametro interno della pagina, non serve al server
        while server.hasSuffix("/") { server.removeLast() }
        guard server.hasPrefix("http://") || server.hasPrefix("https://") else {
            respondError(task, 400, "Indirizzo del server non valido")
            return
        }
        let query = params.map { AppSchemeHandler.encode($0.0) + "=" + AppSchemeHandler.encode($0.1) }.joined(separator: "&")
        guard let target = URL(string: server + "/player_api.php" + (query.isEmpty ? "" : "?" + query)) else {
            respondError(task, 400, "Indirizzo del server non valido")
            return
        }
        attempt(target, task, 0, "")
    }

    /// Un tentativo verso il server; se risponde vuoto, chiude o è sovraccarico, riprova (fino a 3 volte).
    private func attempt(_ target: URL, _ task: WKURLSchemeTask, _ number: Int, _ lastError: String) {
        if number >= 3 {
            respondError(task, 502, lastError + " Ho riprovato 3 volte.")
            return
        }
        guard isActive(task) else { return }
        let delay = number == 0 ? 0.0 : Double(number) * 0.9
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            var request = URLRequest(url: target)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let job = self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    self.attempt(target, task, number + 1, "Il server non risponde (" + AppSchemeHandler.describe(error) + ").")
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 {
                    self.respondError(task, 502, "Il server ha rifiutato la richiesta (errore \(code)): controlla username, password e che l'abbonamento sia attivo.")
                    return
                }
                if code == 429 || code >= 500 {
                    self.attempt(target, task, number + 1, "Il server è sovraccarico (errore \(code)).")
                    return
                }
                if code >= 400 {
                    self.respondError(task, 502, "Il server ha risposto con errore \(code).")
                    return
                }
                guard let body = data, AppSchemeHandler.looksLikeJSON(body) else {
                    self.attempt(target, task, number + 1, "Il server ha inviato una risposta vuota o incompleta.")
                    return
                }
                self.respond(task, 200, "application/json; charset=utf-8", body)
            }
            job.resume()
        }
    }

    /// Controllo veloce: inizia con { o [ e finisce con } o ] (una risposta troncata non passa).
    private static func looksLikeJSON(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var i = 0
        var j = bytes.count - 1
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF { i = 3 }
        while i <= j && isSpace(bytes[i]) { i += 1 }
        while j >= i && isSpace(bytes[j]) { j -= 1 }
        if i > j { return false }
        let first = bytes[i], last = bytes[j]
        return (first == 0x7B && last == 0x7D) || (first == 0x5B && last == 0x5D)
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        return b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09
    }

    private static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut: return "tempo scaduto"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "indirizzo del server non trovato"
        case NSURLErrorCannotConnectToHost: return "connessione rifiutata"
        case NSURLErrorNetworkConnectionLost: return "connessione interrotta"
        case NSURLErrorNotConnectedToInternet: return "iPhone senza connessione a internet"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "problema di connessione sicura"
        default: return "connessione non riuscita"
        }
    }

    // MARK: indirizzi

    /// Legge i parametri come li scrive la pagina (URLSearchParams: lo spazio diventa "+").
    private static func parseQuery(_ query: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(parts[0]).replacingOccurrences(of: "+", with: " ")
            let rawValue = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "+", with: " ") : ""
            let key = rawKey.removingPercentEncoding ?? rawKey
            let value = rawValue.removingPercentEncoding ?? rawValue
            if !out.contains(where: { $0.0 == key }) { out.append((key, value)) }
        }
        return out
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}

/// Molti server IPTV usano certificati non validi: come VLC, li accettiamo.
private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

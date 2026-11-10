import Foundation

/// Archivio delle impostazioni (playlist, tema, lista, progressi) in un file dell'app.
/// Ogni valore è conservato come testo JSON, esattamente come lo manda la pagina.
final class SettingsStore {

    static let shared = SettingsStore()

    private var values: [String: String] = [:]
    private let fileURL: URL
    private let queue = DispatchQueue(label: "it.xtream.player.store")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        fileURL = base.appendingPathComponent("impostazioni.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: String] {
            values = saved
        }
    }

    /// Salva un valore (testo JSON); "null" lo cancella.
    func set(_ key: String, _ json: String) {
        queue.sync {
            if json == "null" {
                values.removeValue(forKey: key)
            } else {
                // accetta solo JSON valido, così il file resta sempre leggibile
                guard let data = json.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return }
                values[key] = json
            }
            if let data = try? JSONSerialization.data(withJSONObject: values, options: []) {
                try? data.write(to: fileURL, options: [.atomic])
            }
        }
    }

    /// Tutte le impostazioni come un unico oggetto JSON, per la pagina.
    func json() -> String {
        return queue.sync {
            let parts = values.map { SettingsStore.quote($0.key) + ":" + $0.value }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    /// Testo tra virgolette, con i caratteri speciali protetti (formato JSON).
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

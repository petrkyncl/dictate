import Foundation

/// Čte diktáty, které démon uložil na disk.
///
/// Démon zapisuje přepis hned, jak vznikne. Když se text nepodaří vložit
/// (jiná appka převzala fokus, uživatel přepnul okno), pořád je odsud
/// dosažitelný — to je ta pojistka proti ztraceným diktátům.
enum History {
    struct Entry {
        let date: Date
        let text: String
        var preview: String {
            let one = text.replacingOccurrences(of: "\n", with: " ")
            return one.count <= 52 ? one : String(one.prefix(52)) + "…"
        }
    }

    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictate/history")
    }

    static func recent(_ limit: Int = 20) -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Entry? in
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = obj["text"] as? String, !text.isEmpty
                else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Entry(date: date, text: text)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}

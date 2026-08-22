import Foundation

/// Diktáty, které démon uložil na disk.
///
/// Přepis se zapisuje hned, jak vznikne. Když se text nepodaří vložit
/// (jiná appka převzala fokus, uživatel přepnul okno), pořád je odsud
/// dosažitelný — to je pojistka proti ztraceným diktátům.
enum History {
    struct Entry {
        let file: URL
        let date: Date
        let text: String
        let raw: String
        let audio: URL?

        var hasAudio: Bool {
            guard let audio else { return false }
            return FileManager.default.fileExists(atPath: audio.path)
        }
    }

    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictate/history")
    }

    static func recent(_ limit: Int = 200) -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Entry? in
                guard let data = try? Data(contentsOf: url),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = o["text"] as? String, !text.isEmpty
                else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let audio = (o["audio"] as? String).map { URL(fileURLWithPath: $0) }
                return Entry(file: url, date: date, text: text,
                             raw: o["raw"] as? String ?? "", audio: audio)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    static func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.file)
        // Audio se maže i se složkou nahrávky — bez přepisu je k ničemu.
        if let audio = entry.audio {
            try? FileManager.default.removeItem(at: audio.deletingLastPathComponent())
        }
    }
}

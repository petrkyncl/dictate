import Foundation

/// Nastavení v JSON souboru, ne v okně s předvolbami.
///
/// Glosář poroste a bude se v něm hledat a kopírovat — na to je textový
/// soubor lepší nástroj než formulář. Démon čte tentýž soubor.
struct Config {
    var hotkey: String = "rightOption"
    var chunkSeconds: Int = 10
    var model: String = "claude-haiku-4-5"

    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictate/config.json")
    }

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { writeDefault(); return c }
        if let v = o["hotkey"] as? String { c.hotkey = v }
        if let v = o["chunk_seconds"] as? Int, (3...30).contains(v) { c.chunkSeconds = v }
        if let v = o["model"] as? String { c.model = v }
        return c
    }

    var key: HotkeyMonitor.Key {
        hotkey == "leftOption" ? .leftOption : .rightOption
    }

    /// Vzor se vypíše i s komentářem, aby bylo jasné, co se smí měnit.
    static func writeDefault() {
        let text = """
        {
          "_": "Nastavení Dictate. Po změně restartuj appku (a démona, měníš-li glosář).",

          "hotkey": "rightOption",
          "_hotkey": "rightOption nebo leftOption. Levý ⌥ je pracovní klávesa (⌥+Delete, ⌥+šipky, @ a # na české klávesnici) — na push-to-talk se hodí hůř.",

          "chunk_seconds": 10,
          "_chunk_seconds": "Po kolika sekundách poslat kousek k přepisu už během mluvení. Kratší = menší zbytek po puštění klávesy, ale víc volání.",

          "model": "claude-haiku-4-5",
          "_model": "Model pro úpravu textu. Haiku je nejrychlejší i nejlevnější a v testu na češtině nebyl horší než Sonnet ani Opus.",

          "_glosar": "Slovník vlastních jmen je v dictate/cleanup.py (proměnná GLOSSARY) a v dictate/daemon.py (ASR_PROMPT)."
        }
        """
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

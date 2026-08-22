import Foundation

/// Nastavení v JSON souboru, ne v okně s předvolbami.
///
/// Glosář poroste a bude se v něm hledat a kopírovat — na to je textový
/// soubor lepší nástroj než formulář. Démon čte tentýž soubor.
struct Config {
    var hotkey: String = "rightOption"
    var mode: String = "hold"
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
        if let v = o["mode"] as? String { c.mode = v }
        if let v = o["model"] as? String { c.model = v }
        return c
    }

    var trigger: HotkeyMonitor.Trigger {
        HotkeyMonitor.Trigger(rawValue: hotkey) ?? .rightOption
    }

    var hotkeyMode: HotkeyMonitor.Mode {
        HotkeyMonitor.Mode(rawValue: mode) ?? .hold
    }

    /// Vzor se vypíše i s komentářem, aby bylo jasné, co se smí měnit.
    static func writeDefault() {
        let text = """
        {
          "_": "Nastavení Dictate. Po změně restartuj appku (a démona, měníš-li glosář).",

          "hotkey": "rightOption",
          "_hotkey": "rightOption, leftOption nebo f5. Levý ⌥ je pracovní klávesa (⌥+Delete, ⌥+šipky, @ a # na české klávesnici). F5 funguje až po vypnutí systémového diktování v System Settings → Keyboard → Dictation.",

          "mode": "hold",
          "_mode": "hold = drž klávesu a mluv. toggle = ťukni dvakrát pro start, jednou pro konec; na dlouhý diktát pohodlnější.",

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

import AppKit

/// Vloží text do aktivní aplikace přes schránku a syntetické ⌘V.
///
/// Přes Accessibility API by to bylo elegantnější, ale v Electronu (Slack,
/// VS Code) je to nespolehlivé. Schránka funguje všude; původní obsah
/// se vrátí zpátky.
enum TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { copy[type] = item.data(forType: type) }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        paste()

        // Schránku vrátit až po vložení — dřív by se vložil starý obsah.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pb.clearContents()
            for dict in saved ?? [] {
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                pb.writeObjects([item])
            }
        }
    }

    private static func paste() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let v: CGKeyCode = 9   // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

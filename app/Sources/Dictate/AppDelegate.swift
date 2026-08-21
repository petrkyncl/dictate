import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private var daemon = DaemonClient()
    private var sessionID: String?
    private var micName = "—"
    private var lastLine = "Připraveno"
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusItem.buildStatusItem()
        render(.idle)
        buildMenu()

        guard HotkeyMonitor.hasAccessibilityPermission(prompt: true) else {
            lastLine = "Chybí oprávnění Accessibility"
            alert("Chybí oprávnění",
                  "Povol Dictate v System Settings → Privacy & Security → Accessibility, "
                  + "pak appku spusť znovu.")
            return
        }
        guard hotkey.start() else {
            lastLine = "Nepodařilo se zachytit klávesu"
            return
        }
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }

        if let mic = MicPicker.pick() { micName = mic.name }
        buildMenu()
    }

    // MARK: - Diktát

    private func beginDictation() {
        guard !busy else { return }
        guard let mic = MicPicker.pick() else {
            lastLine = "Nenašel jsem mikrofon"; render(.error); buildMenu(); return
        }
        micName = mic.name
        do {
            daemon = DaemonClient()
            try daemon.connect()
            sessionID = try daemon.start()
            recorder.onChunk = { [weak self] url in
                guard let self, let sid = self.sessionID else { return }
                // Přepis běží už během mluvení — po puštění klávesy zbyde jen ocas.
                try? self.daemon.chunk(session: sid, path: url.path)
            }
            _ = try recorder.start(micIndex: mic.index)
            render(.recording)
            lastLine = "Nahrávám…"
        } catch {
            sessionID = nil
            lastLine = error.localizedDescription
            render(.error)
        }
        buildMenu()
    }

    private func endDictation() {
        guard let sid = sessionID else { return }
        sessionID = nil
        busy = true
        render(.thinking)
        lastLine = "Přepisuji…"
        buildMenu()

        let tail = recorder.stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.daemon.finish(session: sid, tail: tail?.path) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let reply):
                    let text = reply.text ?? ""
                    if text.isEmpty {
                        self.lastLine = "Nic jsem neslyšel"
                        self.render(.idle)
                    } else {
                        TextInserter.insert(text)
                        let t = reply.timing
                        let secs = (t?.asr_tail ?? 0) + (t?.llm ?? 0)
                        self.lastLine = String(format: "%d znaků · %.1f s · $%.4f",
                                               text.count, secs, reply.usd ?? 0)
                        self.render(.idle)
                    }
                case .failure(let e):
                    self.lastLine = e.localizedDescription
                    self.render(.error)
                }
                self.daemon.close()
                self.buildMenu()
            }
        }
    }

    // MARK: - UI

    private enum State { case idle, recording, thinking, error }

    private func render(_ s: State) {
        let symbol: String
        switch s {
        case .idle: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .thinking: symbol = "waveform"
        case .error: symbol = "exclamationmark.triangle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictate")
        statusItem.button?.image?.isTemplate = true
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled(lastLine))
        menu.addItem(.separator())
        menu.addItem(disabled("Mikrofon: \(micName)"))
        menu.addItem(disabled("Zkratka: podrž pravý ⌥"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Otevřít složku s nahrávkami",
                                action: #selector(openRecordings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ukončit Dictate",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil {
            item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        }
        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func openRecordings() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictate/recordings")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

extension NSStatusItem {
    static func buildStatusItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }
}

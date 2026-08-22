import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let hud = RecordingHUD()
    private let mainWindow = MainWindow()
    private var daemon = DaemonClient()
    private var sessionID: String?
    private var micName = "—"
    private var lastLine = "Připraveno"
    private var busy = false
    private var config = Config()
    private var hotkeyArmed = false
    private var needsPermission = false
    private var permissionWatch: Timer?
    private var setupRefresh: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.writeDefault()
        config = Config.load()
        statusItem = NSStatusItem.buildStatusItem()
        render(.idle)
        if CommandLine.arguments.contains("--diagnose") {
            FileHandle.standardError.write("""
            statusItem \(statusItem != nil), button \(statusItem.button != nil), \
            image \(statusItem.button?.image != nil), visible \(statusItem.isVisible), \
            accessibility \(HotkeyMonitor.hasAccessibilityPermission(prompt: false))

            """.data(using: .utf8)!)
        }

        hotkey.trigger = config.trigger
        hotkey.mode = config.hotkeyMode
        hotkey.onKeyDetected = { [weak self] in
            guard let self else { return }
            mainWindow.keyPressCount += 1
            mainWindow.refresh()
        }
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }

        if let mic = MicPicker.pick() { micName = mic.name }
        // Mikrofon: bez oprávnění ffmpeg jen visí a nevytvoří soubor, takže
        // by diktát tiše skončil prázdným textem. Radši se zeptat hned.
        if !Recorder.micAuthorized {
            Recorder.requestMicAccess { [weak self] _ in self?.syncWindow() }
        }
        mainWindow.onGrantClicked = { [weak self] in self?.requestPermission() }
        mainWindow.onRegenerate = { [weak self] entry, fromAudio in
            self?.rework(entry, fromAudio: fromAudio)
        }
        syncWindow()
        armHotkey()
        buildMenu()

        // Okno se ukáže, jen když něco chybí. Když je vše v pořádku, appka
        // tiše sedí v liště a neotravuje.
        startSetupRefresh()
        // Okno se ukáže při prvním spuštění a vždy, když něco chybí.
        if needsPermission || !UserDefaults.standard.bool(forKey: "seenWindow") {
            UserDefaults.standard.set(true, forKey: "seenWindow")
            mainWindow.show()
        }
    }

    private var hotkeyLabel: String { config.trigger.label }
    private var hotkeyHelp: String { config.hotkeyMode.help }

    /// Spuštění už běžící aplikace (Spotlight, Dock, druhé `open`) okno otevře.
    /// Bez tohoto by se uživatel k oknu dostal jen přes ikonku v liště —
    /// a ta na plné liště s výřezem nemusí být vidět.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    /// Zkusí zapnout odchyt klávesy. Když chybí oprávnění, NEBLOKUJE —
    /// jen si o ně řekne a dál sleduje, jestli je uživatel neudělil.
    ///
    /// Modální dialog by tady byl fatální: aplikace bez Docku se s ním
    /// zasekne, ikonka se nevykreslí a navenek to vypadá, že nedělá nic.
    private func armHotkey() {
        guard !hotkeyArmed else { return }

        guard HotkeyMonitor.hasAccessibilityPermission(prompt: false) else {
            needsPermission = true
            lastLine = "Chybí oprávnění Accessibility"
            render(.error)
            startPermissionWatch()
            buildMenu()
            return
        }
        guard hotkey.start() else {
            // Oprávnění je, ale tap se nevytvořil — jiná příčina než práva.
            lastLine = "Odchyt klávesy se nezdařil (tap)"
            render(.error)
            buildMenu()
            syncWindow()
            return
        }
        hotkeyArmed = true
        needsPermission = false
        permissionWatch?.invalidate()
        permissionWatch = nil
        lastLine = "Připraveno"
        render(.idle)
        buildMenu()
        syncWindow()
        startSetupRefresh()
    }

    /// Po udělení oprávnění se appka rozjede sama, bez restartu.
    private func startPermissionWatch() {
        guard permissionWatch == nil else { return }
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if HotkeyMonitor.hasAccessibilityPermission(prompt: false) { armHotkey() }
        }
    }

    /// Okno se drží aktuální samo — jinak zůstane viset na textu, který
    /// platil ve chvíli otevření, a uživatel podle něj hledá neexistující problém.
    private func startSetupRefresh() {
        guard setupRefresh == nil else { return }
        setupRefresh = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let missing = !HotkeyMonitor.hasAccessibilityPermission(prompt: false)
            if missing != needsPermission {
                needsPermission = missing
                if missing { hotkeyArmed = false; armHotkey() }
            }
            syncWindow()
        }
    }

    @objc private func requestPermission() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        startPermissionWatch()
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
            recorder.onLevel = { [weak self] level in self?.hud.update(level: level) }
            _ = try recorder.start(micIndex: mic.index)
            hud.show(.listening)
            render(.recording)
            lastLine = "Nahrávám…"
        } catch {
            sessionID = nil
            lastLine = error.localizedDescription
            mainWindow.note("⚠️  " + error.localizedDescription)
            render(.error)
            hud.hide()
        }
        buildMenu()
    }

    private func endDictation() {
        guard let sid = sessionID else { return }
        sessionID = nil
        busy = true
        hud.show(.thinking)
        render(.thinking)
        lastLine = "Přepisuji…"
        buildMenu()

        let tail = recorder.stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.daemon.finish(session: sid, tail: tail?.path) }
            DispatchQueue.main.async {
                self.busy = false
                self.hud.hide()
                switch result {
                case .success(let reply):
                    let text = reply.text ?? ""
                    if text.isEmpty {
                        // Prázdný výsledek má dvě různé příčiny a uživatel
                        // musí vědět, o kterou jde.
                        let why = self.recorder.lastError ?? "Nic jsem neslyšel"
                        self.lastLine = why
                        self.mainWindow.note("⚠️  " + why)
                        self.render(.error)
                    } else {
                        TextInserter.insert(text)
                        let t = reply.timing
                        let secs = (t?.asr_tail ?? 0) + (t?.llm ?? 0)
                        self.lastLine = String(format: "%d znaků · %.1f s · $%.4f",
                                               text.count, secs, reply.usd ?? 0)
                        self.render(.idle)
                        self.mainWindow.reload()
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
        guard let button = statusItem.button else { return }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictate") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            // Bez záložního textu by byla položka prázdná a nešla by najít.
            button.image = nil
            button.title = "◉"
        }
        button.toolTip = "Dictate — " + lastLine
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled(lastLine))
        if needsPermission {
            let fix = NSMenuItem(title: "Udělit oprávnění Accessibility…",
                                 action: #selector(requestPermission), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(disabled("Po udělení se appka rozjede sama"))
        }
        menu.addItem(.separator())
        menu.addItem(disabled("Mikrofon: \(micName)"))
        menu.addItem(disabled("Zkratka: \(hotkeyHelp) \(hotkeyLabel)"))
        menu.addItem(.separator())

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Otevřít okno Dictate…",
                                action: #selector(showSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Nastavení…",
                                action: #selector(openConfig), keyEquivalent: ","))
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

    /// Přegenerování běží mimo hlavní vlákno — přepis z audia trvá sekundy
    /// a okno by mezitím zamrzlo.
    private func rework(_ entry: History.Entry, fromAudio: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = DaemonClient()
            var result: Result<String, Error>
            do {
                try client.connect()
                result = .success(try client.rework(file: entry.file.path, fromAudio: fromAudio))
            } catch {
                result = .failure(error)
            }
            client.close()
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self.mainWindow.reload()
                    self.mainWindow.note(text.isEmpty ? "Nic se nezměnilo" : "✅  Hotovo")
                case .failure(let e):
                    self.mainWindow.note("Nepovedlo se: \(e.localizedDescription)")
                }
            }
        }
    }

    @objc private func showSetup() {
        syncWindow()
        mainWindow.reload()
        mainWindow.show()
    }

    /// Přenese aktuální stav do okna. Jedno místo, aby okno nikdy
    /// nezůstalo viset na informaci, která už neplatí.
    private func syncWindow() {
        mainWindow.needsPermission = needsPermission
        mainWindow.isArmed = hotkeyArmed
        mainWindow.hotkeyLabel = hotkeyLabel
        mainWindow.hotkeyHelp = hotkeyHelp
        mainWindow.micName = micName
        mainWindow.micAuthorized = Recorder.micAuthorized
        mainWindow.refresh()
    }

    @objc private func openConfig() {
        Config.writeDefault()
        NSWorkspace.shared.open(Config.url)
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

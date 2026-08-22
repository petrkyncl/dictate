import AppKit

/// Hlavní okno aplikace: stav nahoře, historie diktátů pod tím.
///
/// Ikonka v liště je nespolehlivá — na Macu s výřezem a plnou lištou ji
/// macOS tiše skryje. Okno je proto hlavní rozhraní, lišta jen zkratka.
final class MainWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, HistoryCellDelegate {
    var onGrantClicked: (() -> Void)?
    /// Akce, které musí vyřídit démon (běh na pozadí, hlášení výsledku).
    var onRegenerate: ((History.Entry, Bool) -> Void)?

    /// Počet zachycených stisků klávesy. Rostoucí číslo je jediný spolehlivý
    /// důkaz, že odchyt funguje — přepínač v System Settings umí ukazovat
    /// zapnuto i pro záznam, který už neplatí.
    var keyPressCount = 0
    var isArmed = false
    var needsPermission = false
    var hotkeyLabel = "pravý ⌥"
    var hotkeyHelp = "podrž"
    var micName = "—"
    var micAuthorized = true

    private var window: NSWindow?
    private var statusField: NSTextField?
    private var liveField: NSTextField?
    private var grantButton: NSButton?
    private var table: NSTableView?
    private var footer: NSTextField?
    private var entries: [History.Entry] = []

    func show() {
        if window == nil { build() }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // bez Docku se okno samo nedostane dopředu
    }

    func reload() {
        entries = History.recent(200)
        table?.reloadData()
        recalcHeights()
        refresh()
    }

    /// Po změně šířky okna se musí přepočítat výšky řádků, jinak text
    /// buď přetéká, nebo za sebou nechává prázdno.
    func recalcHeights() {
        guard let t = table, t.numberOfRows > 0 else { return }
        t.noteHeightOfRows(withIndexesChanged: IndexSet(0..<t.numberOfRows))
    }

    func refresh() {
        grantButton?.isHidden = !needsPermission

        if !micAuthorized {
            statusField?.stringValue =
                "⚠️  Chybí oprávnění k mikrofonu.\n\n"
                + "System Settings → Privacy & Security → Microphone, zapni tam Dictate.\n"
                + "Bez něj nahrávání tiše skončí prázdným textem."
            statusField?.textColor = .labelColor
            grantButton?.isHidden = false
        } else if needsPermission {
            statusField?.stringValue =
                "⚠️  Chybí oprávnění Accessibility — bez něj Dictate nevidí stisk "
                + "klávesy a nemůže vkládat text.\n"
                + "Pokud je Dictate v seznamu už zapnutý, vypni ho a znovu zapni: macOS "
                + "u přepínače drží záznam svázaný s konkrétní verzí aplikace."
            statusField?.textColor = .labelColor
        } else {
            statusField?.stringValue =
                "\(hotkeyHelp.prefix(1).uppercased() + hotkeyHelp.dropFirst()) "
                + "\(hotkeyLabel), mluv — text se vloží tam, kde je kurzor.\n"
                + "Mikrofon: \(micName)"
            statusField?.textColor = .secondaryLabelColor
        }

        if !isArmed {
            liveField?.stringValue = "Odchyt klávesy: neaktivní"
            liveField?.textColor = .secondaryLabelColor
        } else if keyPressCount == 0 {
            liveField?.stringValue = "Zkouška: stiskni teď \(hotkeyLabel) — naskočí tu číslo"
            liveField?.textColor = .secondaryLabelColor
        } else {
            liveField?.stringValue = "✅  Stisk zachycen \(keyPressCount)× — odchyt funguje"
            liveField?.textColor = .systemGreen
        }

        if footer?.stringValue.isEmpty ?? true || footer?.stringValue.hasPrefix("Zatím") == true
            || footer?.stringValue.contains("diktát") == true {
            footer?.stringValue = entries.isEmpty
                ? "Zatím žádné diktáty"
                : "\(entries.count) diktátů · nabídka ⌄ vpravo u každého záznamu"
        }
    }

    // MARK: - Sestavení

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Dictate"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 380)
        w.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        content.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "Dictate")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 24, y: 512, width: 300, height: 26)
        title.autoresizingMask = [.minYMargin]

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.frame = NSRect(x: 24, y: 452, width: 572, height: 56)
        status.autoresizingMask = [.width, .minYMargin]

        let live = NSTextField(labelWithString: "")
        live.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        live.frame = NSRect(x: 24, y: 428, width: 572, height: 16)
        live.autoresizingMask = [.width, .minYMargin]

        let grant = NSButton(title: "Otevřít nastavení oprávnění",
                             target: self, action: #selector(grant))
        grant.bezelStyle = .rounded
        grant.frame = NSRect(x: 24, y: 392, width: 230, height: 30)
        grant.autoresizingMask = [.minYMargin]

        let header = NSTextField(labelWithString: "Historie diktátů")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.frame = NSRect(x: 24, y: 362, width: 200, height: 18)
        header.autoresizingMask = [.minYMargin]

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 44, width: 572, height: 310))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let t = NSTableView(frame: scroll.bounds)
        t.dataSource = self
        t.delegate = self
        t.usesAlternatingRowBackgroundColors = true
        t.headerView = nil
        t.style = .inset
        t.gridStyleMask = []
        t.allowsMultipleSelection = false

        let col = NSTableColumn(identifier: .init("entry"))
        col.resizingMask = .autoresizingMask
        // Bez explicitní šířky zůstane sloupec ~40 bodů široký a text
        // se do buňky nevejde — vypadá to, že se historie nenačetla.
        col.width = scroll.contentSize.width - 4
        col.minWidth = 200
        t.addTableColumn(col)
        t.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = t

        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.frame = NSRect(x: 24, y: 18, width: 572, height: 16)
        f.autoresizingMask = [.width]

        [title, status, live, grant, header, scroll, f].forEach { content.addSubview($0) }
        w.contentView = content

        window = w; statusField = status; liveField = live
        grantButton = grant; table = t; footer = f

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
            self?.recalcHeights()
        }
    }

    // MARK: - Tabulka

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let cell = tableView.makeView(withIdentifier: HistoryCell.identifier, owner: self)
            as? HistoryCell ?? {
                let c = HistoryCell(frame: .zero)
                c.identifier = HistoryCell.identifier
                return c
            }()
        cell.configure(entries[row], row: row, delegate: self)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 40 }
        // Šířka tabulky je při prvním sestavení ještě nulová; brát ji odtud
        // by dalo nesmyslně vysoké řádky a text by se nevešel.
        let w = tableView.enclosingScrollView?.contentSize.width
            ?? (tableView.bounds.width > 0 ? tableView.bounds.width : 560)
        return HistoryCell.height(for: entries[row].text, width: w)
    }

    // MARK: - Akce u záznamu

    func historyCell(_ cell: HistoryCell, didChoose action: HistoryCell.Action, row: Int) {
        guard row < entries.count else { return }
        let e = entries[row]
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(e.text, forType: .string)
            note("✅  Zkopírováno do schránky")
        case .regenerate:
            note("Přegeneruji úpravu…")
            onRegenerate?(e, false)
        case .retranscribe:
            note("Přepisuji znovu z audia…")
            onRegenerate?(e, true)
        case .revealAudio:
            if let a = e.audio { NSWorkspace.shared.activateFileViewerSelecting([a]) }
        case .delete:
            History.delete(e)
            reload()
            note("Záznam smazán")
        }
    }

    func note(_ text: String) {
        footer?.stringValue = text
    }

    @objc private func grant() { onGrantClicked?() }
}

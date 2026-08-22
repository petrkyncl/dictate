import AppKit

/// Hlavní okno aplikace: stav nahoře, historie diktátů pod tím.
///
/// Ikonka v liště je nespolehlivá — na Macu s výřezem a plnou lištou ji
/// macOS tiše skryje. Okno je proto hlavní rozhraní, lišta jen zkratka.
final class MainWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onGrantClicked: (() -> Void)?

    /// Počet zachycených stisků klávesy. Rostoucí číslo je jediný spolehlivý
    /// důkaz, že odchyt funguje — přepínač v System Settings umí ukazovat
    /// zapnuto i pro záznam, který už neplatí.
    var keyPressCount = 0
    var isArmed = false
    var needsPermission = false
    var hotkeyLabel = "levý ⌥"
    var micName = "—"

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
        entries = History.recent(100)
        table?.reloadData()
        refresh()
    }

    func refresh() {
        grantButton?.isHidden = !needsPermission

        if needsPermission {
            statusField?.stringValue =
                "⚠️  Chybí oprávnění Accessibility — bez něj Dictate nevidí stisk "
                + "klávesy a nemůže vkládat text.\n"
                + "Pokud je Dictate v seznamu už zapnutý, vypni ho a znovu zapni: macOS "
                + "u přepínače drží záznam svázaný s konkrétní verzí aplikace."
            statusField?.textColor = .labelColor
        } else {
            statusField?.stringValue =
                "Podrž \(hotkeyLabel), mluv, pusť — text se vloží tam, kde je kurzor.\n"
                + "Mikrofon: \(micName)"
            statusField?.textColor = .secondaryLabelColor
        }

        if !isArmed {
            liveField?.stringValue = "Odchyt klávesy: neaktivní"
            liveField?.textColor = .secondaryLabelColor
        } else if keyPressCount == 0 {
            liveField?.stringValue = "Zkouška: podrž teď \(hotkeyLabel) — naskočí tu číslo"
            liveField?.textColor = .secondaryLabelColor
        } else {
            liveField?.stringValue = "✅  Stisk zachycen \(keyPressCount)× — odchyt funguje"
            liveField?.textColor = .systemGreen
        }

        footer?.stringValue = entries.isEmpty
            ? "Zatím žádné diktáty"
            : "\(entries.count) diktátů · klikni na řádek a zkopíruje se do schránky"
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

        let header = NSTextField(labelWithString: "Historie")
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
        t.rowHeight = 34
        t.usesAlternatingRowBackgroundColors = true
        t.headerView = nil
        t.target = self
        t.action = #selector(rowClicked)

        let timeCol = NSTableColumn(identifier: .init("time"))
        timeCol.width = 108
        let textCol = NSTableColumn(identifier: .init("text"))
        textCol.width = 440
        t.addTableColumn(timeCol)
        t.addTableColumn(textCol)
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
    }

    // MARK: - Tabulka

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let e = entries[row]
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail

        if tableColumn?.identifier.rawValue == "time" {
            let fmt = DateFormatter()
            fmt.dateFormat = "d. M. HH:mm"
            label.stringValue = fmt.string(from: e.date)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = e.text.replacingOccurrences(of: "\n", with: " ")
            label.font = .systemFont(ofSize: 12)
            label.toolTip = e.text
        }
        return label
    }

    @objc private func rowClicked() {
        guard let t = table, t.clickedRow >= 0, t.clickedRow < entries.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[t.clickedRow].text, forType: .string)
        footer?.stringValue = "✅  Zkopírováno do schránky"
    }

    @objc private func grant() { onGrantClicked?() }
}

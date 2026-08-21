import AppKit

/// Okno, které řekne, co appce chybí, a nabídne to spravit.
///
/// Ikonka v liště je nespolehlivý nosič téhle informace: na Macu s výřezem
/// a plnou lištou ji macOS tiše skryje a aplikace pak navenek nedělá vůbec
/// nic, aniž by řekla proč. Okno se ukáže vždycky.
final class SetupWindow {
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    var onGrantClicked: (() -> Void)?

    func show(needsPermission: Bool, hotkeyLabel: String, mic: String) {
        if window == nil { build() }
        refresh(needsPermission: needsPermission, hotkeyLabel: hotkeyLabel, mic: mic)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // bez Docku se okno samo nedostane dopředu
    }

    func close() {
        window?.orderOut(nil)
    }

    func refresh(needsPermission: Bool, hotkeyLabel: String, mic: String) {
        statusLabel?.stringValue = needsPermission
            ? "⚠️  Chybí oprávnění Accessibility.\n\n"
              + "Bez něj Dictate nevidí stisk klávesy a nemůže vkládat text.\n"
              + "Klikni na tlačítko níž, v seznamu zapni Dictate.\n\n"
              + "Appka se rozjede sama, jakmile oprávnění udělíš — nemusíš ji restartovat."
            : "✅  Vše připraveno.\n\n"
              + "Podrž \(hotkeyLabel), mluv, pusť.\n"
              + "Text se vloží tam, kde je kurzor.\n\n"
              + "Mikrofon: \(mic)\n\n"
              + "Tohle okno můžeš zavřít, Dictate běží dál v liště."
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Dictate"
        w.isReleasedWhenClosed = false

        let content = NSView(frame: w.contentLayoutRect)

        let title = NSTextField(labelWithString: "Dictate")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = NSRect(x: 28, y: 258, width: 400, height: 30)

        let sub = NSTextField(labelWithString: "Diktování do češtiny")
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 28, y: 236, width: 400, height: 18)

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 13)
        status.frame = NSRect(x: 28, y: 84, width: 404, height: 140)
        status.isSelectable = false

        let grant = NSButton(title: "Otevřít nastavení oprávnění",
                             target: self, action: #selector(grant))
        grant.bezelStyle = .rounded
        grant.keyEquivalent = "\r"
        grant.frame = NSRect(x: 28, y: 28, width: 240, height: 32)

        content.addSubview(title)
        content.addSubview(sub)
        content.addSubview(status)
        content.addSubview(grant)
        w.contentView = content

        window = w
        statusLabel = status
    }

    @objc private func grant() {
        onGrantClicked?()
    }
}

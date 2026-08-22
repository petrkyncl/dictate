import AppKit

protocol HistoryCellDelegate: AnyObject {
    func historyCell(_ cell: HistoryCell, didChoose action: HistoryCell.Action, row: Int)
}

/// Řádek historie: čas, CELÝ text diktátu a nabídka akcí.
///
/// Text se záměrně nezkracuje třemi tečkami — smysl historie je vidět,
/// co jsem řekl, ne hádat to z prvních padesáti znaků.
final class HistoryCell: NSTableCellView {
    enum Action { case copy, regenerate, retranscribe, revealAudio, delete }

    static let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
    static let horizontalInset: CGFloat = 130     // čas vlevo + nabídka vpravo + mezery
    static let verticalPadding: CGFloat = 20
    /// Strop výšky řádku. Bez něj by jeden pětiminutový diktát zabral
    /// celé okno a ostatní záznamy by nebyly vidět.
    static let maxHeight: CGFloat = 260

    weak var delegate: HistoryCellDelegate?
    var row: Int = 0
    private var hasAudio = false

    private let time = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        time.textColor = .tertiaryLabelColor

        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping

        more.bezelStyle = .inline
        more.isBordered = false
        more.target = self
        more.action = #selector(chose)

        [time, body, more].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            time.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            time.widthAnchor.constraint(equalToConstant: 74),

            body.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 10),
            body.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -8),
            body.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -9),

            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            more.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            more.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: History.Entry, row: Int, delegate: HistoryCellDelegate) {
        self.row = row
        self.delegate = delegate
        self.hasAudio = entry.hasAudio

        let fmt = DateFormatter()
        fmt.dateFormat = "d.M. HH:mm"
        time.stringValue = fmt.string(from: entry.date)
        body.stringValue = entry.text
        // Bez tohohle si zalamovací pole spočítá šířku jako jeden dlouhý
        // řádek a výška řádku pak nesedí s tím, co se vykreslí.
        body.preferredMaxLayoutWidth = max(120, bounds.width - Self.horizontalInset)

        more.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))   // titul pull-down
        m.addItem(item("Kopírovat text", .copy))
        m.addItem(.separator())
        m.addItem(item("Přegenerovat úpravu", .regenerate))
        let re = item("Přepsat znovu z audia", .retranscribe)
        re.isEnabled = hasAudio
        m.addItem(re)
        let rv = item("Ukázat audio ve Finderu", .revealAudio)
        rv.isEnabled = hasAudio
        m.addItem(rv)
        m.addItem(.separator())
        m.addItem(item("Smazat záznam", .delete))
        return m
    }

    private func item(_ title: String, _ action: Action) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(chose), keyEquivalent: "")
        i.target = self
        i.representedObject = action
        return i
    }

    @objc private func chose(_ sender: Any?) {
        guard let action = (sender as? NSMenuItem)?.representedObject as? Action
                ?? more.selectedItem?.representedObject as? Action else { return }
        delegate?.historyCell(self, didChoose: action, row: row)
    }

    /// Výška řádku podle délky textu — jinak by dlouhý diktát nebyl vidět celý.
    static func height(for text: String, width: CGFloat) -> CGFloat {
        let w = max(200, width - horizontalInset)
        let box = (text as NSString).boundingRect(
            with: NSSize(width: w, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(maxHeight, max(40, ceil(box.height) + verticalPadding))
    }
}

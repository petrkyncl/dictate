import AppKit

/// Plovoucí pilulka u spodního okraje obrazovky během diktátu.
///
/// Je to `NSPanel` s `.nonactivatingPanel`, ne obyčejné okno — jinak by
/// při zobrazení ukradlo fokus tomu poli, do kterého se má text vložit.
/// Myš jím prochází skrz a přežije i přepnutí na jinou plochu.
final class RecordingHUD {
    enum Mode {
        case listening
        case thinking

        /// Popisek jen tam, kde nese informaci. Při nahrávání uživatel ví,
        /// že mluví — číst si u toho „Poslouchám" je zbytečné, stačí čas.
        var label: String {
            switch self {
            case .listening: ""
            case .thinking: "přepisuji"
            }
        }
    }

    private var panel: NSPanel?
    private var meter: MeterView?
    private var label: NSTextField?
    private var clock: Timer?
    private var startedAt: Date?
    private var mode: Mode = .listening

    func show(_ mode: Mode) {
        if panel == nil { build() }
        self.mode = mode
        meter?.isThinking = (mode == .thinking)
        switch mode {
        case .listening:
            startedAt = Date()
            startClock()
        case .thinking:
            stopClock()
            meter?.level = 0
        }
        refreshLabel()
        reposition()
        panel?.orderFrontRegardless()      // zobraz bez aktivace aplikace
        panel?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel?.animator().alphaValue = 1
        }
    }

    func update(level: Double) {
        meter?.level = level
    }

    private func startClock() {
        stopClock()
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshLabel()
        }
    }

    private func stopClock() {
        clock?.invalidate(); clock = nil
    }

    /// U dlouhého diktátu je dobré vidět, jak dlouho už mluvíš — ASR i cena
    /// rostou s délkou a po pěti minutách monologu se to hodí vědět.
    private func refreshLabel() {
        guard let label else { return }
        guard mode == .listening, let start = startedAt else {
            label.stringValue = mode.label
            return
        }
        let s = Int(Date().timeIntervalSince(start))
        label.stringValue = String(format: "%d:%02d", s / 60, s % 60)
    }

    func hide() {
        stopClock()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Sestavení

    private func build() {
        let size = NSSize(width: 150, height: 44)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = size.height / 2
        blur.layer?.masksToBounds = true

        let m = MeterView(frame: NSRect(x: 22, y: 11, width: 56, height: 22))
        let t = NSTextField(labelWithString: "")
        t.frame = NSRect(x: 84, y: 13, width: 52, height: 18)
        t.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        t.alignment = .left
        t.textColor = .labelColor

        blur.addSubview(m)
        blur.addSubview(t)
        p.contentView = blur

        panel = p; meter = m; label = t
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                     y: f.minY + 96))
    }
}

/// Sloupečky reagující na skutečnou hlasitost z mikrofonu.
private final class MeterView: NSView {
    private static let barCount = 5
    private var bars = [Double](repeating: 0.12, count: barCount)
    private var timer: Timer?

    var level: Double = 0 {
        didSet { pushLevel(level) }
    }

    var isThinking = false {
        didSet { isThinking ? startPulse() : stopPulse() }
    }

    private func pushLevel(_ v: Double) {
        // Posun doleva, nový vzorek zprava — vzniká tím běžící vlnka.
        bars.removeFirst()
        // Odmocnina roztáhne tichý konec škály — jinak se u běžné řeči
        // sloupečky sotva hnou a nepoznáš ticho od šepotu.
        bars.append(max(0.12, sqrt(v)))
        needsDisplay = true
    }

    private func startPulse() {
        stopPulse()
        var phase = 0.0
        timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            guard let self else { return }
            phase += 0.5
            for i in 0..<Self.barCount {
                bars[i] = 0.25 + 0.35 * abs(sin(phase + Double(i) * 0.6))
            }
            needsDisplay = true
        }
    }

    private func stopPulse() {
        timer?.invalidate(); timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        let w = 5.0, gap = 12.0
        for (i, v) in bars.enumerated() {
            let h = max(5.0, bounds.height * v)
            let r = NSRect(x: Double(i) * gap, y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }

    deinit { stopPulse() }
}

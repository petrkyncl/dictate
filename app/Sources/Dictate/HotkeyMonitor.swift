import AppKit

/// Odchyt spouštěcí klávesy. Umí dva režimy a tři klávesy.
///
/// PROČ NE Fn: systém na ni má vlastní akci (přepnutí jazyka, emoji paleta)
/// a spolehlivě ji spolknout nejde — řeší ji WindowServer pod úrovní,
/// kam CGEventTap dosáhne.
///
/// PROČ F5 FUNGUJE JEN PODMÍNĚNĚ: má na sobě mikrofon, protože spouští
/// systémový Dictate od Applu. Dokud ho uživatel nevypne v System Settings
/// → Keyboard → Dictation, sebere si událost systém dřív než my.
final class HotkeyMonitor {
    enum Trigger: String {
        case leftOption, rightOption, f5

        var keyCode: CGKeyCode {
            switch self {
            case .leftOption: 58
            case .rightOption: 61
            case .f5: 96
            }
        }
        /// Modifikátor chodí jako flagsChanged, běžná klávesa jako keyDown/keyUp.
        var isModifier: Bool { self != .f5 }

        var label: String {
            switch self {
            case .leftOption: "levý ⌥"
            case .rightOption: "pravý ⌥"
            case .f5: "F5"
            }
        }
    }

    enum Mode: String {
        /// Držíš = nahrává, pustíš = přepíše.
        case hold
        /// Dvojité ťuknutí zapne, další ťuknutí vypne. Na dlouhý diktát,
        /// kde je držení klávesy nepohodlné.
        case toggle

        var help: String {
            switch self {
            case .hold: "podrž"
            case .toggle: "ťukni dvakrát pro start, jednou pro konec —"
            }
        }
    }

    var trigger: Trigger = .rightOption
    var mode: Mode = .hold

    /// V režimu hold: jak dlouho držet, než se začne nahrávat. Bez prodlevy
    /// by u levého ⌥ spustilo nahrávání každé ⌥+Delete nebo ⌥+šipka.
    var holdThreshold: TimeInterval = 0.25
    /// V režimu toggle: maximální rozestup dvou ťuknutí.
    var doubleTapWindow: TimeInterval = 0.45

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fire při každém stisku sledované klávesy — aby šlo v okně ukázat,
    /// že appka uživatele slyší, i když se zrovna nezačalo nahrávat.
    var onKeyDetected: (() -> Void)?

    private var tap: CFMachPort?
    private var isDown = false
    private var armTimer: Timer?
    private var recording = false
    private var lastTapAt: Date?

    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let bits: UInt64 = (1 << UInt64(CGEventType.flagsChanged.rawValue))
                         | (1 << UInt64(CGEventType.keyDown.rawValue))
                         | (1 << UInt64(CGEventType.keyUp.rawValue))
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // událost nepohlcujeme, klávesa musí dál fungovat
            eventsOfInterest: CGEventMask(bits),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                Unmanaged<HotkeyMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue().handle(event, type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil
        armTimer?.invalidate(); armTimer = nil
        isDown = false; recording = false; lastTapAt = nil
    }

    /// Vnější zastavení (např. z menu), ať stav nezůstane rozjetý.
    func forceStop() {
        guard recording else { return }
        recording = false
        onRelease?()
    }

    private func handle(_ event: CGEvent, type: CGEventType) {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Jiná klávesa během držení modifikátoru => je to zkratka, ne diktát.
        if type == .keyDown, code != trigger.keyCode, isDown, mode == .hold {
            DispatchQueue.main.async { self.cancelArm() }
            return
        }
        guard code == trigger.keyCode else { return }

        let down: Bool
        if trigger.isModifier {
            guard type == .flagsChanged else { return }
            down = event.flags.contains(.maskAlternate)
        } else {
            guard type == .keyDown || type == .keyUp else { return }
            down = (type == .keyDown)
            if down && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        }
        guard down != isDown else { return }
        isDown = down

        DispatchQueue.main.async {
            if down { self.onKeyDetected?() }
            self.mode == .hold ? self.handleHold(down: down) : self.handleToggle(down: down)
        }
    }

    private func handleHold(down: Bool) {
        if down {
            recording = false
            armTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold,
                                            repeats: false) { [weak self] _ in
                guard let self, isDown else { return }
                recording = true
                onPress?()
            }
        } else {
            armTimer?.invalidate(); armTimer = nil
            if recording { recording = false; onRelease?() }
        }
    }

    private func handleToggle(down: Bool) {
        guard down else { return }
        if recording {                       // jedno ťuknutí = konec
            recording = false
            lastTapAt = nil
            onRelease?()
            return
        }
        let now = Date()
        if let last = lastTapAt, now.timeIntervalSince(last) <= doubleTapWindow {
            lastTapAt = nil
            recording = true
            onPress?()
        } else {
            lastTapAt = now
        }
    }

    private func cancelArm() {
        armTimer?.invalidate(); armTimer = nil
        if recording { recording = false; onRelease?() }
    }
}

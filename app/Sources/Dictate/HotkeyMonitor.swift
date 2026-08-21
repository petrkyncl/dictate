import AppKit

/// Push-to-talk na pravém ⌥.
///
/// Proč pravý a ne levý: levý ⌥ je pracovní klávesa (⌥+Delete maže slovo,
/// ⌥+šipky skáčou po slovech, na české klávesnici se přes něj píše @ a #).
/// Pravý je na většině rozložení prakticky nepoužívaný.
///
/// Proč ne Fn: systém na ni má vlastní akci (přepnutí jazyka nebo emoji
/// paleta) a spolknout ji spolehlivě nejde — řeší ji WindowServer níž,
/// než kam CGEventTap dosáhne.
final class HotkeyMonitor {
    enum Key: CGKeyCode {
        case rightOption = 61
        case leftOption = 58
    }

    var key: Key = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// Jak dlouho se musí klávesa držet, než se začne nahrávat.
    /// Bez téhle prodlevy by u levého ⌥ spustilo nahrávání každé
    /// ⌥+Delete nebo ⌥+šipka.
    var holdThreshold: TimeInterval = 0.25

    private var tap: CFMachPort?
    private var isDown = false
    private var armTimer: Timer?
    private var didFire = false

    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        // keyDown je potřeba, aby šlo poznat ⌥+jiná klávesa (zkratka)
        // od samotného držení ⌥ (diktát).
        let flagsBit: UInt64 = 1 << UInt64(CGEventType.flagsChanged.rawValue)
        let keyBit: UInt64 = 1 << UInt64(CGEventType.keyDown.rawValue)
        let mask = CGEventMask(flagsBit | keyBit)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,            // událost nepohlcujeme — ⌥ musí dál fungovat
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(event, type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ event: CGEvent, type: CGEventType) {
        // Jiná klávesa během držení ⌥ => je to zkratka, ne diktát.
        if type == .keyDown {
            if isDown { DispatchQueue.main.async { self.cancelArm() } }
            return
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == key.rawValue else { return }
        let down = event.flags.contains(.maskAlternate)
        guard down != isDown else { return }
        isDown = down

        DispatchQueue.main.async {
            if down {
                self.didFire = false
                self.armTimer = Timer.scheduledTimer(withTimeInterval: self.holdThreshold,
                                                     repeats: false) { [weak self] _ in
                    guard let self, self.isDown else { return }
                    self.didFire = true
                    self.onPress?()
                }
            } else {
                self.armTimer?.invalidate()
                self.armTimer = nil
                if self.didFire {
                    self.didFire = false
                    self.onRelease?()
                }
            }
        }
    }

    /// Zruší čekání na spuštění — zmáčkla se jiná klávesa, jde o zkratku.
    private func cancelArm() {
        armTimer?.invalidate()
        armTimer = nil
        if didFire {                 // stihlo se to rozjet, uklidit
            didFire = false
            onRelease?()
        }
    }
}

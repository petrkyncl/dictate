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

    private var tap: CFMachPort?
    private var isDown = false

    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,            // událost nepohlcujeme — ⌥ musí dál fungovat
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(event)
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

    private func handle(_ event: CGEvent) {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == key.rawValue else { return }
        let down = event.flags.contains(.maskAlternate)
        guard down != isDown else { return }
        isDown = down
        DispatchQueue.main.async { down ? self.onPress?() : self.onRelease?() }
    }
}

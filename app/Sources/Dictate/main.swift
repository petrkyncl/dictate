import AppKit

// Diagnostika: `Dictate --list-mics` vypise poradi zarizeni tak, jak je vidi
// AVCaptureDevice. Musi sedet s cislovanim ffmpegu (`-f avfoundation
// -list_devices true`), jinak by se nahravalo z jineho mikrofonu.
if CommandLine.arguments.contains("--list-mics") {
    for d in MicPicker.devices() {
        print("[\(d.index)] \(d.name)\(d.isBlocked ? "   (blokováno — kamera/virtuální)" : "")")
    }
    if let p = MicPicker.pick() {
        print("→ vybráno: [\(p.index)] \(p.name)")
    } else {
        print("→ žádný použitelný mikrofon")
    }
    exit(0)
}

// Diagnostika: ukaze indikator na 6 s s nasimulovanou hlasitosti,
// aby sel zkontrolovat vzhled bez mackani klavesy.
if CommandLine.arguments.contains("--test-hud") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    for (i, sc) in NSScreen.screens.enumerated() {
        print("displej \(i): \(sc.frame)  \(sc == NSScreen.main ? "← main" : "")")
    }
    let hud = RecordingHUD()
    hud.show(.listening)
    print("indikátor umístěn na: \(NSScreen.main?.visibleFrame ?? .zero)")
    var t = 0.0
    Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
        t += 0.08
        hud.update(level: 0.15 + 0.55 * abs(sin(t * 3.1)) * Double.random(in: 0.6...1.0))
        if t > 3.5 { timer.invalidate(); hud.show(.thinking) }
    }
    Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { _ in
        hud.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // jen ikona v liste, zadny Dock ani okno
app.run()

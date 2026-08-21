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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // jen ikona v liste, zadny Dock ani okno
app.run()

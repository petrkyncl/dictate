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

// Diagnostika: projde celý řetěz (mikrofon → ffmpeg → démon → text) bez
// nutnosti mačkat klávesu. Ověřuje to, co jinak jde otestovat jen ručně.
if CommandLine.arguments.contains("--selftest") {
    let seconds = Double(CommandLine.arguments.last ?? "") ?? 6.0
    guard let mic = MicPicker.pick() else {
        print("✗ žádný mikrofon"); exit(1)
    }
    print("mikrofon: [\(mic.index)] \(mic.name)")
    let rec = Recorder()
    let client = DaemonClient()
    do {
        try client.connect()
        let sid = try client.start()
        let session = try rec.start(micIndex: mic.index)
        print("nahrávám \(Int(seconds)) s do \(session.dir.path)…")
        rec.onLevel = { _ in }
        Thread.sleep(forTimeInterval: seconds)
        let tail = rec.stop()
        print("soubor: \(tail?.lastPathComponent ?? "ŽÁDNÝ ⚠")")
        if let t = tail {
            let size = (try? FileManager.default.attributesOfItem(atPath: t.path)[.size] as? Int) ?? 0
            print("velikost: \(size ?? 0) B")
        }
        let reply = try client.finish(session: sid, tail: tail?.path)
        print("text: \(reply.text ?? "")")
        print("čas: ASR \(reply.timing?.asr_tail ?? 0)s + LLM \(reply.timing?.llm ?? 0)s")
        exit(0)
    } catch {
        print("✗ \(error.localizedDescription)"); exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // jen ikona v liste, zadny Dock ani okno
app.run()

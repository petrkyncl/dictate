import AVFoundation
import Foundation

/// Nahrává přes ffmpeg do jednoho souboru, průběžně na disk.
///
/// DŘÍV se nahrávka řezala na 10s kousky, aby se přepisovaly už během
/// mluvení a po puštění klávesy zbyl jen zbytek. Změřeno na korpusu:
/// stálo to 40 % slov (3010 → 1812) a halucinace vyskočily z 2 na 75.
/// Dva důvody se sečetly — hranice padaly doprostřed slov, a normalizace
/// hlasitosti puštěná na kousek plný ticha zesílí šum na úroveň řeči,
/// do kterého pak Whisper halucinuje.
///
/// Latence se řeší až potom, co bude kvalita jistá.
final class Recorder {
    struct Session {
        let id: String
        let dir: URL
    }

    var chunkSeconds = 10   // ponecháno pro budoucí dělení v tichu
    private var process: Process?
    private var session: Session?
    private var sent = Set<String>()
    private var poller: Timer?
    private var errorText = ""

    /// Volá se pro každý dokončený kousek, ještě během mluvení.
    var onChunk: ((URL) -> Void)?

    /// Poslední chyba nahrávání — aby se dala ukázat uživateli místo ticha.
    private(set) var lastError: String?

    /// Stav přístupu k mikrofonu. Bez něj ffmpeg jen visí a nevytvoří soubor,
    /// takže by diktát tiše skončil prázdným textem.
    static var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Hlasitost 0…1 pro indikátor. Skutečné RMS z ffmpegu, ne animace naoko —
    /// jinak by ukazatel vesele skákal i s odpojeným mikrofonem.
    var onLevel: ((Double) -> Void)?

    private static var recordingsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictate/recordings")
    }

    enum Failure: LocalizedError {
        case noMicAccess
        case noOutput(String)
        var errorDescription: String? {
            switch self {
            case .noMicAccess:
                "Chybí oprávnění k mikrofonu (System Settings → Privacy & Security → Microphone)"
            case .noOutput(let detail):
                "Nahrávka nevznikla. \(detail)"
            }
        }
    }

    func start(micIndex: Int) throws -> Session {
        guard Self.micAuthorized else { throw Failure.noMicAccess }
        let id = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = Self.recordingsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: FFmpeg.path)
        p.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-f", "avfoundation", "-i", ":\(micIndex)",
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
            // astats zvuk nemění, jen měří; ametadata to tiskne na stdout.
            // Levá ruka tak dává hlasitost pro indikátor, pravá píše kousky.
            "-af", "astats=metadata=1:reset=1,"
                 + "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
            dir.appendingPathComponent("audio.wav").path,
        ]
        p.standardInput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe
        errorText = ""
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self?.errorText += s
        }
        let levels = Pipe()
        p.standardOutput = levels
        try p.run()
        readLevels(from: levels)

        process = p
        session = Session(id: id, dir: dir)
        sent.removeAll()
        return session!
    }

    /// Ukončí nahrávání a vrátí celou nahrávku k přepisu.
    func stop() -> URL? {
        poller?.invalidate(); poller = nil
        if let p = process, p.isRunning {
            // "q" ukončí ffmpeg čistě (dopíše hlavičku WAV). Kdyby nezareagoval,
            // NESMÍ se čekat donekonečna — stop() běží na hlavním vlákně
            // a appka by zamrzla.
            if let input = p.standardInput as? Pipe {
                try? input.fileHandleForWriting.write(contentsOf: Data("q\n".utf8))
                try? input.fileHandleForWriting.close()
            }
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if p.isRunning {
                p.terminate()                       // hlavička může chybět,
                usleep(200_000)                     // ale zvuk je na disku
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        onLevel = nil
        defer { session = nil }

        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        let file = chunks().last
        if file == nil {
            lastError = errorText.isEmpty
                ? "ffmpeg nezapsal žádný zvuk — zkontroluj mikrofon."
                : errorText.split(separator: "\n").last.map(String.init) ?? errorText
        } else {
            lastError = nil
        }
        return file
    }

    /// Čte RMS v dBFS z ffmpegu a převádí na 0…1 pro ukazatel.
    private func readLevels(from pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = ""
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer += String(data: data, encoding: .utf8) ?? ""
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl])
                    buffer = String(buffer[buffer.index(after: nl)...])
                    guard let r = line.range(of: "RMS_level="),
                          let db = Double(line[r.upperBound...]) else { continue }
                    // -50 dBFS = ticho, -10 = hlasitá řeč
                    let norm = min(max((db + 50) / 40, 0), 1)
                    DispatchQueue.main.async { self?.onLevel?(norm) }
                }
            }
        }
    }

    private func chunks() -> [URL] {
        guard let dir = session?.dir,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
    }

    private func flushCompleted() {
        let all = chunks()
        // Poslední soubor ffmpeg právě zapisuje — ten ještě není hotový.
        for url in all.dropLast() where !sent.contains(url.lastPathComponent) {
            sent.insert(url.lastPathComponent)
            onChunk?(url)
        }
    }
}

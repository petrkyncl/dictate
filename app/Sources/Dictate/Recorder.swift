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

    /// Volá se pro každý dokončený kousek, ještě během mluvení.
    var onChunk: ((URL) -> Void)?

    /// Hlasitost 0…1 pro indikátor. Skutečné RMS z ffmpegu, ne animace naoko —
    /// jinak by ukazatel vesele skákal i s odpojeným mikrofonem.
    var onLevel: ((Double) -> Void)?

    private static var recordingsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Dictate/recordings")
    }

    func start(micIndex: Int) throws -> Session {
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
        p.standardError = Pipe()
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
        if let p = process, p.isRunning, let input = p.standardInput as? Pipe {
            input.fileHandleForWriting.write("q".data(using: .utf8)!)   // ffmpeg končí čistě
            p.waitUntilExit()
        }
        process = nil
        onLevel = nil
        defer { session = nil }

        return chunks().last
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

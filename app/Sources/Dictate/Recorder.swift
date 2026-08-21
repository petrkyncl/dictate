import Foundation

/// Nahrává přes ffmpeg se segmentací na ~10s kousky.
///
/// Proč ffmpeg a ne AVAudioEngine: segmentový muxer zapisuje kousky na disk
/// průběžně sám, takže "audio je na disku dřív, než se přepisuje" platí
/// z principu, ne díky naší pečlivosti. A přepis se rozjede už během mluvení.
final class Recorder {
    struct Session {
        let id: String
        let dir: URL
    }

    private static let chunkSeconds = 10
    private var process: Process?
    private var session: Session?
    private var sent = Set<String>()
    private var poller: Timer?

    /// Volá se pro každý dokončený kousek, ještě během mluvení.
    var onChunk: ((URL) -> Void)?

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
            "-f", "segment", "-segment_time", "\(Self.chunkSeconds)",
            "-reset_timestamps", "1",
            dir.appendingPathComponent("chunk_%03d.wav").path,
        ]
        p.standardInput = Pipe()
        p.standardError = Pipe()
        try p.run()

        process = p
        session = Session(id: id, dir: dir)
        sent.removeAll()

        // Kousek je hotový ve chvíli, kdy ffmpeg založí následující soubor.
        poller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.flushCompleted()
        }
        return session!
    }

    /// Ukončí nahrávání a vrátí poslední (dosud neodeslaný) kousek jako "ocas".
    func stop() -> URL? {
        poller?.invalidate(); poller = nil
        if let p = process, p.isRunning, let input = p.standardInput as? Pipe {
            input.fileHandleForWriting.write("q".data(using: .utf8)!)   // ffmpeg končí čistě
            p.waitUntilExit()
        }
        process = nil
        defer { session = nil }

        let remaining = chunks().filter { !sent.contains($0.lastPathComponent) }
        // Všechny až na poslední pošli jako běžné kousky; poslední je ocas.
        for url in remaining.dropLast() {
            sent.insert(url.lastPathComponent)
            onChunk?(url)
        }
        return remaining.last
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

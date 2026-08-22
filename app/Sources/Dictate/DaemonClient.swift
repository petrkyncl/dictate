import Darwin
import Foundation

/// Klient rezidentního démona (unix socket, JSON po řádcích).
/// Démon drží Whisper v RAM — bez něj by každý diktát platil 1,1 s za načtení modelu.
final class DaemonClient {
    struct Timing: Decodable {
        let asr_tail: Double
        let asr_behem_mluveni: Double
        let llm: Double
    }
    struct FinishReply: Decodable {
        let text: String?
        let timing: Timing?
        let usd: Double?
        let error: String?
    }

    enum Failure: LocalizedError {
        case cannotConnect
        case daemon(String)
        var errorDescription: String? {
            switch self {
            case .cannotConnect: "Démon neběží. Spusť: dictate/run-daemon.sh"
            case .daemon(let m): m
            }
        }
    }

    static let socketPath = NSHomeDirectory() + "/Library/Application Support/Dictate/daemon.sock"

    private var fd: Int32 = -1
    private var buffer = Data()

    func connect() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.cannotConnect }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self),
                        src, capacity - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard ok == 0 else { close(); throw Failure.cannotConnect }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    @discardableResult
    private func send(_ msg: [String: Any]) throws -> [String: Any] {
        var line = try JSONSerialization.data(withJSONObject: msg)
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: off), raw.count - off, 0)
                guard n > 0 else { throw Failure.cannotConnect }
                off += n
            }
        }
        return try readLine()
    }

    private func readLine() throws -> [String: Any] {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                buffer = buffer[(nl + 1)...]
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { throw Failure.cannotConnect }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func ping() -> Bool {
        guard let r = try? send(["cmd": "ping"]) else { return false }
        return r["ready"] as? Bool ?? false
    }

    func start() throws -> String {
        let r = try send(["cmd": "start"])
        guard let s = r["session"] as? String else { throw Failure.daemon("démon nevrátil session") }
        return s
    }

    func chunk(session: String, path: String) throws {
        _ = try send(["cmd": "chunk", "session": session, "path": path])
    }

    /// Znovu pustí úpravu textu (levné) nebo celý přepis z audia (dražší).
    func rework(file: String, fromAudio: Bool) throws -> String {
        let raw = try send(["cmd": fromAudio ? "retranscribe" : "regenerate", "file": file])
        if let e = raw["error"] as? String { throw Failure.daemon(e) }
        return raw["text"] as? String ?? ""
    }

    func finish(session: String, tail: String?) throws -> FinishReply {
        var msg: [String: Any] = ["cmd": "finish", "session": session]
        if let tail { msg["path"] = tail }
        let raw = try send(msg)
        let data = try JSONSerialization.data(withJSONObject: raw)
        let reply = try JSONDecoder().decode(FinishReply.self, from: data)
        if let e = reply.error { throw Failure.daemon(e) }
        return reply
    }
}

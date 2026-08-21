import Foundation

enum FFmpeg {
    /// ffmpeg nemusí být na stejném místě na každém stroji.
    static let path: String = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/ffmpeg"
    }()

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// Spustí ffmpeg a vrátí jeho stderr (výpisy zařízení jdou tam, ne na stdout).
    static func stderr(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

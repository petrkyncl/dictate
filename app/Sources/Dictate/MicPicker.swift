import Foundation

/// Vybere vstup podle priority: Scarlett/Focusrite > vestavěný > cokoli dalšího.
///
/// Seznam se čte přímo z ffmpegu, protože ffmpeg pak nahrává podle indexu,
/// který sám vypsal. Spoléhat na to, že se AVCaptureDevice a ffmpeg shodnou
/// v číslování, by fungovalo do prvního přepojení zařízení.
///
/// Kamery a virtuální zařízení se nevyberou nikdy, ani kdyby byly jediné —
/// diktovat do webkamery, když je po ruce mikrofon, nedává smysl.
enum MicPicker {
    private static let preferred = ["scarlett", "focusrite"]
    private static let builtIn = ["macbook", "built-in", "vestav"]
    private static let blocked = ["brio", "obs", "virtual", "camera", "blackhole",
                                  "loopback", "aggregate", "multi-output", "soundflower"]

    struct Device {
        let index: Int
        let name: String
        var isBlocked: Bool {
            let n = name.lowercased()
            return blocked.contains { n.contains($0) }
        }
    }

    /// Audio vstupy tak, jak je čísluje ffmpeg.
    ///
    /// Řádky vypadají takto — vlastní prefix ffmpegu je taky v hranatých
    /// závorkách, takže se musí brát ta poslední dvojice, ne první:
    ///     [AVFoundation indev @ 0x14e…] [1] Scarlett Solo 4th Gen
    static func devices() -> [Device] {
        let out = FFmpeg.stderr(["-f", "avfoundation", "-list_devices", "true", "-i", ""])
        guard let start = out.range(of: "AVFoundation audio devices:") else { return [] }
        let re = try? NSRegularExpression(pattern: #"\[(\d+)\]\s+(.+?)\s*$"#)
        return out[start.upperBound...].split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let m = re?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let ri = Range(m.range(at: 1), in: s), let rn = Range(m.range(at: 2), in: s),
                  let idx = Int(s[ri]) else { return nil }
            let name = String(s[rn])
            return name.isEmpty ? nil : Device(index: idx, name: name)
        }
    }

    static func pick() -> Device? {
        let all = devices().filter { !$0.isBlocked }
        func match(_ needles: [String]) -> Device? {
            all.first { d in needles.contains { d.name.lowercased().contains($0) } }
        }
        return match(preferred) ?? match(builtIn) ?? all.first
    }
}

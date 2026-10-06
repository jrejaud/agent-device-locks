// window-frames — record ONE window (never the screen) as PNG frames with ScreenCaptureKit.
//
//   window-frames <window-id> <fps> <seconds> <out-dir>
//
// Writes <out-dir>/NNNN.png plus <out-dir>/times (one capture timestamp per frame, seconds),
// so a GIF/WebP can be assembled with each frame's true duration. Captures at the display's
// backing scale (2x on Retina). Needs Screen Recording permission. macOS 14+.
import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count == 5, let wid = UInt32(a[1]), let fps = Double(a[2]), let secs = Double(a[3]) else {
    FileHandle.standardError.write("usage: window-frames <window-id> <fps> <seconds> <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
_ = NSApplication.shared   // connects to the window server; ScreenCaptureKit asserts without it
let out = URL(fileURLWithPath: a[4], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func save(_ img: CGImage, _ url: URL) {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        var times: [String] = []
        let start = Date()
        var n = 0
        var found: SCWindow? = nil
        var resolved = Date.distantPast
        while Date().timeIntervalSince(start) < secs {
            let tick = Date()
            // Looking the window up is the slow part, so do it about once a second; that is
            // still often enough to follow a size change (countdown → banner).
            if found == nil || tick.timeIntervalSince(resolved) > 0.9 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                found = content.windows.first(where: { $0.windowID == wid }); resolved = tick
            }
            guard let w = found else { break }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            save(img, out.appendingPathComponent(String(format: "%04d.png", n)))
            times.append(String(format: "%.3f", tick.timeIntervalSince1970))
            n += 1
            let wait = 1.0 / fps - Date().timeIntervalSince(tick)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        try times.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("times"), atomically: true, encoding: .utf8)
        print("\(n) frames → \(out.path)")
    } catch {
        FileHandle.standardError.write("window-frames: \(error)\n".data(using: .utf8)!)
    }
    done.signal()
}
done.wait()

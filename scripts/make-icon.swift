// Renders EchoWave's app icon and packs it into an .icns file.
// Usage: swift scripts/make-icon.swift [output.icns] [preview.png]
import AppKit

let arguments = CommandLine.arguments.dropFirst()
let outputPath = arguments.first ?? "Resources/AppIcon.icns"
let previewPath = arguments.dropFirst().first
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let scale = CGFloat(size) / 1024
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)

    // macOS icon grid: an 824 pt rounded square centered on a 1024 pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow (shadow metrics are in device pixels, so scale them by hand).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 30 * scale, color: color(0x000000, alpha: 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0x1B1240))
    context.fillPath()
    context.restoreGState()

    // Body gradient: deep indigo → violet → blue → cyan.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: sRGB,
                              colors: [color(0x22145E), color(0x5B3FF0), color(0x2F86FF), color(0x24D6EE)] as CFArray,
                              locations: [0, 0.4, 0.74, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 110), end: CGPoint(x: 880, y: 930), options: [])
    // Soft glow behind the waveform.
    let glow = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, alpha: 0.22), color(0xFFFFFF, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 512), endRadius: 400, options: [])
    // Top sheen.
    let sheen = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, alpha: 0.18), color(0xFFFFFF, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    context.restoreGState()

    // Waveform: rounded bars, tallest in the middle.
    let heights: [CGFloat] = [0.22, 0.44, 0.7, 1.0, 0.7, 0.44, 0.22]
    let barWidth: CGFloat = 60
    let gap: CGFloat = 38
    let maxHeight: CGFloat = 480
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = 512 - totalWidth / 2
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 16 * scale, color: color(0x10083A, alpha: 0.35))
    context.setFillColor(color(0xFFFFFF))
    for fraction in heights {
        let height = maxHeight * fraction
        let bar = CGRect(x: x, y: 512 - height / 2, width: barWidth, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    context.fillPath()
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("EchoWave-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (name, size) in sizes {
    writePNG(render(size: size), to: iconset.appendingPathComponent("icon_\(name).png"))
}
if let previewPath {
    writePNG(render(size: 512), to: URL(fileURLWithPath: previewPath))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(outputPath)")

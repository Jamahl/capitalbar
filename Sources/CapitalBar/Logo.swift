import AppKit

// One vector mark, drawn in code, used for both the menu bar glyph and the
// .icns: three rising candlesticks.
enum Logo {
    /// The mark on its own transparent canvas, authored on a 100×100 grid.
    private static func markImage(color: NSColor, size: NSSize, weight: CGFloat = 11) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            drawMark(color: color, in: rect, weight: weight)
            return true
        }
    }

    /// Draws the mark inside `rect`, authored on a 100×100 grid.
    private static func drawMark(color: NSColor, in rect: NSRect, weight: CGFloat = 11) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let t = NSAffineTransform()
        t.translateX(by: rect.minX, yBy: rect.minY)
        t.scaleX(by: rect.width / 100, yBy: rect.height / 100)
        t.concat()
        color.setStroke()
        color.setFill()

        // Candlesticks beat a letterform here: bodies and wicks still read at
        // the 18pt the menu bar gives us.
        let candles: [(x: CGFloat, bodyLow: CGFloat, bodyHigh: CGFloat, wickLow: CGFloat, wickHigh: CGFloat)] = [
            (16, 18, 42, 10, 52),
            (44, 34, 64, 24, 74),
            (72, 54, 88, 44, 96),
        ]
        let bodyWidth: CGFloat = 15

        for c in candles {
            let wick = NSBezierPath()
            wick.move(to: NSPoint(x: c.x + bodyWidth / 2, y: c.wickLow))
            wick.line(to: NSPoint(x: c.x + bodyWidth / 2, y: c.wickHigh))
            wick.lineWidth = weight * 0.52
            wick.lineCapStyle = .round
            wick.stroke()

            let body = NSBezierPath(roundedRect: NSRect(x: c.x, y: c.bodyLow,
                                                        width: bodyWidth, height: c.bodyHigh - c.bodyLow),
                                    xRadius: 4, yRadius: 4)
            body.fill()
        }
    }

    /// Menu bar glyph. Template so macOS tints it for light/dark automatically.
    static func statusImage(height: CGFloat = 18) -> NSImage {
        let image = markImage(color: .black, size: NSSize(width: height, height: height), weight: 12)
        image.isTemplate = true
        return image
    }

    /// App icon tile: dark gradient squircle with the mark in mint.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.width * 0.055 // macOS icons don't fill their canvas
            let tile = rect.insetBy(dx: inset, dy: inset)
            let radius = tile.width * 0.225
            let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

            NSGradient(colors: [
                NSColor(srgbRed: 0.06, green: 0.13, blue: 0.19, alpha: 1),
                NSColor(srgbRed: 0.04, green: 0.22, blue: 0.18, alpha: 1),
            ])?.draw(in: shape, angle: -90)

            let markBox = tile.insetBy(dx: tile.width * 0.21, dy: tile.height * 0.21)
            let mark = markImage(color: NSColor(srgbRed: 0.29, green: 0.87, blue: 0.50, alpha: 1),
                                 size: markBox.size)
            mark.draw(in: markBox)
            return true
        }
    }

    /// Writes an .iconset directory for `iconutil`. Called by install.sh via
    /// `CapitalBar --export-icons <dir>`, so the icon can never drift from the
    /// mark the menu bar draws.
    static func exportIconset(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = base * scale
                let image = appIcon(size: CGFloat(pixels))
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = NSSize(width: pixels, height: pixels)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let suffix = scale == 2 ? "@2x" : ""
                let name = "icon_\(base)x\(base)\(suffix).png"
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }
}

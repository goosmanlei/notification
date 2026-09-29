import AppKit

/// Original vector artwork: a beacon above two displays. Used for the menu and app icon.
enum Artwork {
    static func menu(size: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: size / 20); transform.concat()
            drawGlyph(color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func app(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let scale = NSAffineTransform()
            scale.scale(by: size / 512); scale.concat()
            let tile = NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480), xRadius: 110, yRadius: 110)
            NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.18, blue: 0.24, alpha: 1),
                       ending: NSColor(calibratedRed: 0.02, green: 0.08, blue: 0.13, alpha: 1))?.draw(in: tile, angle: 90)
            let transform = NSAffineTransform()
            transform.translateX(by: 76, yBy: 74); transform.scale(by: 18); transform.concat()
            drawGlyph(color: NSColor(calibratedRed: 0.83, green: 0.96, blue: 0.94, alpha: 1),
                      beacon: NSColor(calibratedRed: 1, green: 0.75, blue: 0.29, alpha: 1))
            return true
        }
    }

    private static func drawGlyph(color: NSColor, beacon: NSColor? = nil) {
        color.setStroke()
        for x: CGFloat in [1, 11] {
            let screen = NSBezierPath(roundedRect: NSRect(x: x, y: 9, width: 8, height: 6.5), xRadius: 1.2, yRadius: 1.2)
            screen.lineWidth = 1.3; screen.stroke()
            let foot = NSBezierPath()
            foot.move(to: NSPoint(x: x + 4, y: 15.5)); foot.line(to: NSPoint(x: x + 4, y: 17.5))
            foot.move(to: NSPoint(x: x + 2.5, y: 17.5)); foot.line(to: NSPoint(x: x + 5.5, y: 17.5))
            foot.lineWidth = 1.3; foot.lineCapStyle = .round; foot.stroke()
        }
        (beacon ?? color).setFill()
        NSBezierPath(roundedRect: NSRect(x: 6.5, y: 1.5, width: 7, height: 3.5), xRadius: 1.7, yRadius: 1.7).fill()
        (beacon ?? color).setStroke()
        let rays = NSBezierPath()
        rays.move(to: NSPoint(x: 4, y: 4)); rays.line(to: NSPoint(x: 2.5, y: 6))
        rays.move(to: NSPoint(x: 16, y: 4)); rays.line(to: NSPoint(x: 17.5, y: 6))
        rays.lineWidth = 1.4; rays.lineCapStyle = .round; rays.stroke()
    }
}

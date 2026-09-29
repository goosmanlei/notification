import AppKit

@main struct RenderIcons {
    static func png(_ image: NSImage, size: Int, to url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let iconset = directory.appendingPathComponent("Notification.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            try png(Artwork.app(size: CGFloat(points)), size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
            try png(Artwork.app(size: CGFloat(points * 2)), size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
        try png(Artwork.app(), size: 512, to: directory.appendingPathComponent("icon.png"))
        try png(Artwork.menu(size: 80), size: 80, to: directory.appendingPathComponent("menu-template.png"))
    }
}

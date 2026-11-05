import AppKit

/// The blackice mark for the menu bar, drawn from the logo's one path in site/public/logo.svg,
/// `M16 2L28 9V23L16 30L4 23V18H16V14H4V9Z` on a 32-unit grid: a hexagon with a channel that
/// enters from the left and stops at the center.
public enum Mark {
    /// The path's corners in order, in the logo's units, y downwards.
    public static let corners: [CGPoint] = [
        CGPoint(x: 16, y: 2), CGPoint(x: 28, y: 9), CGPoint(x: 28, y: 23), CGPoint(x: 16, y: 30), CGPoint(x: 4, y: 23),
        CGPoint(x: 4, y: 18), CGPoint(x: 16, y: 18), CGPoint(x: 16, y: 14), CGPoint(x: 4, y: 14), CGPoint(x: 4, y: 9),
    ]

    /// The corners in an image `height` points tall: the mark fills `markHeight` of it, centered,
    /// and the image is as wide as the mark plus the same margin. y downwards.
    public static func layout(height: CGFloat, markHeight: CGFloat) -> (size: CGSize, corners: [CGPoint]) {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let scale = markHeight / (maxY - minY)
        let margin = (height - markHeight) / 2
        let size = CGSize(width: ((maxX - minX) * scale + 2 * margin).rounded(.up), height: height)
        let left = (size.width - (maxX - minX) * scale) / 2
        return (size, corners.map { CGPoint(x: left + ($0.x - minX) * scale, y: margin + ($0.y - minY) * scale) })
    }

    /// A template image, so that macOS tints it for light, dark and tinted menu bars.
    public static func image(height: CGFloat = 18, markHeight: CGFloat = 16) -> NSImage {
        let (size, points) = layout(height: height, markHeight: markHeight)
        let image = NSImage(size: size, flipped: true) { _ in
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "blackice"
        return image
    }
}

import AppKit

/// A filled, optionally outlined rounded rect drawn with *continuous*
/// (squircle) corners instead of the circular arc `NSBox.cornerRadius` and
/// `CALayer.cornerRadius` draw — the shape macOS itself uses for window
/// backdrops, group cards and app icons.
///
/// Drawn in `draw(_:)` rather than by a layer with `cornerCurve =
/// .continuous`: the shadow behind each card (DropShadowView) needs the
/// same silhouette as an `NSBezierPath` anyway, so both sides share
/// `NSBezierPath.squircle(in:cornerRadius:)` and can't drift apart.
///
/// Nothing is painted outside the squircle path, so the four corners stay
/// fully transparent (alpha 0) — a plain `NSView` draws no background of
/// its own, and this never fills `bounds`. For the window backdrop that
/// means the corner pixels show the desktop through the (non-opaque, clear
/// backgroundColor) window rather than a square of fill peeking past the
/// curve; for a card it means the page shows through.
///
/// `NSColor` is kept and resolved at draw time — the same reason the boxes
/// this replaces used `NSBox.fillColor` rather than
/// `layer.backgroundColor`: a dynamic system/named colour turned into a
/// `CGColor` once resolves against whatever appearance was current back
/// then and never updates again.
final class SquircleBox: NSView {
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A stroke straddles its path, so the shape is inset by half the
        // border width to keep that stroke fully inside `bounds` instead
        // of half of it landing outside the view (where it would be
        // clipped to a ragged half-hairline).
        let half = borderWidth / 2
        let path = NSBezierPath.squircle(
            in: bounds.insetBy(dx: half, dy: half),
            cornerRadius: cornerRadius - half
        )

        fillColor.setFill()
        path.fill()

        if borderWidth > 0 {
            borderColor.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
    }
}

extension NSBezierPath {
    /// The continuous-corner ("squircle") rounded rect, as reverse
    /// engineered from Apple's own shape: instead of a quarter circle, each
    /// corner is three cubic segments whose curvature ramps up and back
    /// down, so it meets the straight edge with no visible curvature step.
    ///
    /// The magic numbers are that published decomposition, expressed as
    /// multiples of the corner radius. Note the curve reaches `1.52866483 *
    /// radius` along each edge — far further than a circular corner of the
    /// same radius, which is why the two never look alike at one number.
    ///
    /// `radius` is clamped so opposite corners can't overrun each other on
    /// a short edge; at the clamp the shape is a full superellipse.
    /// Non-positive radii fall back to a plain rectangle.
    static func squircle(in rect: NSRect, cornerRadius: CGFloat) -> NSBezierPath {
        let limit = min(rect.width, rect.height) / 2 / 1.52866483
        let r = min(cornerRadius, limit)
        guard r > 0 else { return NSBezierPath(rect: rect) }

        let path = NSBezierPath()
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY

        path.move(to: NSPoint(x: minX + 1.52866483 * r, y: minY))
        path.line(to: NSPoint(x: maxX - 1.52866483 * r, y: minY))
        path.curve(
            to: NSPoint(x: maxX - 0.63149399 * r, y: minY + 0.07491139 * r),
            controlPoint1: NSPoint(x: maxX - 1.08849323 * r, y: minY),
            controlPoint2: NSPoint(x: maxX - 0.86840689 * r, y: minY)
        )
        path.curve(
            to: NSPoint(x: maxX - 0.07491139 * r, y: minY + 0.63149399 * r),
            controlPoint1: NSPoint(x: maxX - 0.37282392 * r, y: minY + 0.16905899 * r),
            controlPoint2: NSPoint(x: maxX - 0.16905899 * r, y: minY + 0.37282392 * r)
        )
        path.curve(
            to: NSPoint(x: maxX, y: minY + 1.52866483 * r),
            controlPoint1: NSPoint(x: maxX, y: minY + 0.86840689 * r),
            controlPoint2: NSPoint(x: maxX, y: minY + 1.08849323 * r)
        )

        path.line(to: NSPoint(x: maxX, y: maxY - 1.52866483 * r))
        path.curve(
            to: NSPoint(x: maxX - 0.07491139 * r, y: maxY - 0.63149399 * r),
            controlPoint1: NSPoint(x: maxX, y: maxY - 1.08849323 * r),
            controlPoint2: NSPoint(x: maxX, y: maxY - 0.86840689 * r)
        )
        path.curve(
            to: NSPoint(x: maxX - 0.63149399 * r, y: maxY - 0.07491139 * r),
            controlPoint1: NSPoint(x: maxX - 0.16905899 * r, y: maxY - 0.37282392 * r),
            controlPoint2: NSPoint(x: maxX - 0.37282392 * r, y: maxY - 0.16905899 * r)
        )
        path.curve(
            to: NSPoint(x: maxX - 1.52866483 * r, y: maxY),
            controlPoint1: NSPoint(x: maxX - 0.86840689 * r, y: maxY),
            controlPoint2: NSPoint(x: maxX - 1.08849323 * r, y: maxY)
        )

        path.line(to: NSPoint(x: minX + 1.52866483 * r, y: maxY))
        path.curve(
            to: NSPoint(x: minX + 0.63149399 * r, y: maxY - 0.07491139 * r),
            controlPoint1: NSPoint(x: minX + 1.08849323 * r, y: maxY),
            controlPoint2: NSPoint(x: minX + 0.86840689 * r, y: maxY)
        )
        path.curve(
            to: NSPoint(x: minX + 0.07491139 * r, y: maxY - 0.63149399 * r),
            controlPoint1: NSPoint(x: minX + 0.37282392 * r, y: maxY - 0.16905899 * r),
            controlPoint2: NSPoint(x: minX + 0.16905899 * r, y: maxY - 0.37282392 * r)
        )
        path.curve(
            to: NSPoint(x: minX, y: maxY - 1.52866483 * r),
            controlPoint1: NSPoint(x: minX, y: maxY - 0.86840689 * r),
            controlPoint2: NSPoint(x: minX, y: maxY - 1.08849323 * r)
        )

        path.line(to: NSPoint(x: minX, y: minY + 1.52866483 * r))
        path.curve(
            to: NSPoint(x: minX + 0.07491139 * r, y: minY + 0.63149399 * r),
            controlPoint1: NSPoint(x: minX, y: minY + 1.08849323 * r),
            controlPoint2: NSPoint(x: minX, y: minY + 0.86840689 * r)
        )
        path.curve(
            to: NSPoint(x: minX + 0.63149399 * r, y: minY + 0.07491139 * r),
            controlPoint1: NSPoint(x: minX + 0.16905899 * r, y: minY + 0.37282392 * r),
            controlPoint2: NSPoint(x: minX + 0.37282392 * r, y: minY + 0.16905899 * r)
        )
        path.curve(
            to: NSPoint(x: minX + 1.52866483 * r, y: minY),
            controlPoint1: NSPoint(x: minX + 0.86840689 * r, y: minY),
            controlPoint2: NSPoint(x: minX + 1.08849323 * r, y: minY)
        )

        path.close()
        return path
    }
}

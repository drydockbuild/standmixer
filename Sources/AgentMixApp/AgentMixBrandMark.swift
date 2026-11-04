import SwiftUI

/// Shared 64-unit StandMixer geometry; keep aligned with brand/standmixer-mark.svg.
struct AgentMixBrandMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 64
            context.translateBy(x: (size.width - 64 * scale) / 2, y: (size.height - 64 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: 5)
            let teal = AgentMixTheme.brandTeal
            let style = StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
            context.stroke(Self.mixer, with: .color(teal), style: style)
            var underline = Path(); underline.move(to: CGPoint(x: 10, y: 46)); underline.addLine(to: CGPoint(x: 53, y: 46))
            context.stroke(underline, with: .color(Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)), style: style)
            context.fill(Path(ellipseIn: CGRect(x: 16.2, y: 15.2, width: 3.6, height: 3.6)), with: .color(teal))
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }

    private static var mixer: Path {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 46)); p.addLine(to: CGPoint(x: 14, y: 23)); p.addLine(to: CGPoint(x: 10, y: 23)); p.addLine(to: CGPoint(x: 10, y: 19))
        p.addCurve(to: CGPoint(x: 20, y: 9), control1: CGPoint(x: 10, y: 13.5), control2: CGPoint(x: 14.5, y: 9))
        p.addLine(to: CGPoint(x: 42, y: 9)); p.addCurve(to: CGPoint(x: 52, y: 19), control1: CGPoint(x: 47.5, y: 9), control2: CGPoint(x: 52, y: 13.5))
        p.addLine(to: CGPoint(x: 52, y: 23)); p.addLine(to: CGPoint(x: 23, y: 23)); p.addLine(to: CGPoint(x: 23, y: 46))
        p.move(to: CGPoint(x: 28, y: 29)); p.addLine(to: CGPoint(x: 51, y: 29)); p.addCurve(to: CGPoint(x: 39.5, y: 42), control1: CGPoint(x: 50.2, y: 37.5), control2: CGPoint(x: 46.4, y: 42))
        p.addCurve(to: CGPoint(x: 28, y: 29), control1: CGPoint(x: 32.6, y: 42), control2: CGPoint(x: 29, y: 37.5)); p.closeSubpath()
        p.move(to: CGPoint(x: 39.5, y: 23)); p.addLine(to: CGPoint(x: 39.5, y: 33))
        return p
    }
}

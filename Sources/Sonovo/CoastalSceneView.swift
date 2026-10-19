import SwiftUI

struct CoastalPalette {
    let skyTop: Color
    let skyBottom: Color
    let sun: Color
    let waterTop: Color
    let waterBottom: Color
    let land: Color
    let sunX: CGFloat
    let sunY: CGFloat
    let sunSize: CGFloat
    let boatX: CGFloat

    static let dawn = CoastalPalette(
        skyTop: Color(red: 0.16, green: 0.21, blue: 0.34),
        skyBottom: Color(red: 0.86, green: 0.55, blue: 0.39),
        sun: Color(red: 0.98, green: 0.79, blue: 0.54),
        waterTop: Color(red: 0.20, green: 0.28, blue: 0.36),
        waterBottom: Color(red: 0.06, green: 0.10, blue: 0.14),
        land: Color(red: 0.10, green: 0.13, blue: 0.17),
        sunX: 0.68,
        sunY: 0.44,
        sunSize: 0.13,
        boatX: 0.62
    )

    static let fog = CoastalPalette(
        skyTop: Color(red: 0.48, green: 0.54, blue: 0.59),
        skyBottom: Color(red: 0.79, green: 0.79, blue: 0.76),
        sun: Color(red: 0.92, green: 0.89, blue: 0.82),
        waterTop: Color(red: 0.44, green: 0.50, blue: 0.54),
        waterBottom: Color(red: 0.26, green: 0.32, blue: 0.36),
        land: Color(red: 0.30, green: 0.35, blue: 0.38),
        sunX: 0.34,
        sunY: 0.38,
        sunSize: 0.10,
        boatX: 0.72
    )

    static let dusk = CoastalPalette(
        skyTop: Color(red: 0.16, green: 0.18, blue: 0.33),
        skyBottom: Color(red: 0.77, green: 0.42, blue: 0.44),
        sun: Color(red: 0.96, green: 0.68, blue: 0.44),
        waterTop: Color(red: 0.20, green: 0.23, blue: 0.36),
        waterBottom: Color(red: 0.07, green: 0.09, blue: 0.15),
        land: Color(red: 0.11, green: 0.12, blue: 0.20),
        sunX: 0.58,
        sunY: 0.50,
        sunSize: 0.11,
        boatX: 0.45
    )

    static let noon = CoastalPalette(
        skyTop: Color(red: 0.35, green: 0.56, blue: 0.78),
        skyBottom: Color(red: 0.81, green: 0.89, blue: 0.91),
        sun: Color(red: 1.0, green: 0.96, blue: 0.84),
        waterTop: Color(red: 0.25, green: 0.44, blue: 0.55),
        waterBottom: Color(red: 0.11, green: 0.25, blue: 0.32),
        land: Color(red: 0.21, green: 0.31, blue: 0.34),
        sunX: 0.76,
        sunY: 0.24,
        sunSize: 0.08,
        boatX: 0.38
    )

    static let slate = CoastalPalette(
        skyTop: Color(red: 0.23, green: 0.29, blue: 0.34),
        skyBottom: Color(red: 0.56, green: 0.63, blue: 0.66),
        sun: Color(red: 0.85, green: 0.82, blue: 0.74),
        waterTop: Color(red: 0.20, green: 0.30, blue: 0.34),
        waterBottom: Color(red: 0.09, green: 0.15, blue: 0.18),
        land: Color(red: 0.14, green: 0.20, blue: 0.22),
        sunX: 0.46,
        sunY: 0.30,
        sunSize: 0.09,
        boatX: 0.70
    )

    static let ember = CoastalPalette(
        skyTop: Color(red: 0.25, green: 0.16, blue: 0.16),
        skyBottom: Color(red: 0.85, green: 0.47, blue: 0.30),
        sun: Color(red: 1.0, green: 0.76, blue: 0.42),
        waterTop: Color(red: 0.23, green: 0.18, blue: 0.19),
        waterBottom: Color(red: 0.09, green: 0.07, blue: 0.08),
        land: Color(red: 0.15, green: 0.11, blue: 0.12),
        sunX: 0.30,
        sunY: 0.52,
        sunSize: 0.15,
        boatX: 0.56
    )

    static let deep = CoastalPalette(
        skyTop: Color(red: 0.05, green: 0.09, blue: 0.16),
        skyBottom: Color(red: 0.19, green: 0.29, blue: 0.39),
        sun: Color(red: 0.62, green: 0.78, blue: 0.84),
        waterTop: Color(red: 0.06, green: 0.13, blue: 0.18),
        waterBottom: Color(red: 0.02, green: 0.05, blue: 0.07),
        land: Color(red: 0.04, green: 0.08, blue: 0.11),
        sunX: 0.78,
        sunY: 0.20,
        sunSize: 0.05,
        boatX: 0.34
    )

    static let pale = CoastalPalette(
        skyTop: Color(red: 0.67, green: 0.72, blue: 0.76),
        skyBottom: Color(red: 0.90, green: 0.89, blue: 0.86),
        sun: Color(red: 0.96, green: 0.94, blue: 0.88),
        waterTop: Color(red: 0.57, green: 0.64, blue: 0.68),
        waterBottom: Color(red: 0.40, green: 0.48, blue: 0.53),
        land: Color(red: 0.42, green: 0.49, blue: 0.52),
        sunX: 0.20,
        sunY: 0.34,
        sunSize: 0.07,
        boatX: 0.76
    )

    static let stills: [CoastalPalette] = [
        dawn, fog, dusk, noon, slate, ember, deep, pale
    ]
}

struct CoastalSceneView: View {
    let palette: CoastalPalette
    var showsBoat = true

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }

            let horizon = size.height * 0.62
            drawSky(context: &context, size: size, horizon: horizon)
            drawSun(context: &context, size: size, horizon: horizon)
            drawLand(context: &context, size: size, horizon: horizon)
            drawWater(context: &context, size: size, horizon: horizon)
            drawFog(context: &context, size: size, horizon: horizon)
            if showsBoat {
                drawBoat(context: &context, size: size, horizon: horizon)
            }
            drawVignette(context: &context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func drawSky(context: inout GraphicsContext, size: CGSize, horizon: CGFloat) {
        let skyRect = CGRect(x: 0, y: 0, width: size.width, height: horizon + 1)
        context.fill(
            Path(skyRect),
            with: .linearGradient(
                Gradient(colors: [palette.skyTop, palette.skyBottom]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: horizon)
            )
        )
    }

    private func drawSun(context: inout GraphicsContext, size: CGSize, horizon: CGFloat) {
        let sunSize = min(size.width, size.height) * palette.sunSize
        let center = CGPoint(
            x: size.width * palette.sunX,
            y: horizon * palette.sunY
        )

        let glowRect = CGRect(
            x: center.x - sunSize * 1.8,
            y: center.y - sunSize * 1.8,
            width: sunSize * 3.6,
            height: sunSize * 3.6
        )
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    palette.sun.opacity(0.22),
                    palette.sun.opacity(0.0)
                ]),
                center: center,
                startRadius: 0,
                endRadius: sunSize * 1.8
            )
        )

        let sunRect = CGRect(
            x: center.x - sunSize / 2,
            y: center.y - sunSize / 2,
            width: sunSize,
            height: sunSize
        )
        context.fill(Path(ellipseIn: sunRect), with: .color(palette.sun.opacity(0.92)))
    }

    private func drawLand(context: inout GraphicsContext, size: CGSize, horizon: CGFloat) {
        var backHill = Path()
        backHill.move(to: CGPoint(x: 0, y: horizon))
        backHill.addCurve(
            to: CGPoint(x: size.width * 0.38, y: horizon - size.height * 0.03),
            control1: CGPoint(x: size.width * 0.10, y: horizon - size.height * 0.07),
            control2: CGPoint(x: size.width * 0.24, y: horizon - size.height * 0.01)
        )
        backHill.addCurve(
            to: CGPoint(x: size.width, y: horizon),
            control1: CGPoint(x: size.width * 0.56, y: horizon - size.height * 0.05),
            control2: CGPoint(x: size.width * 0.76, y: horizon + size.height * 0.01)
        )
        backHill.closeSubpath()
        context.fill(backHill, with: .color(palette.land.opacity(0.55)))

        var foreground = Path()
        foreground.move(to: CGPoint(x: 0, y: horizon))
        foreground.addCurve(
            to: CGPoint(x: size.width, y: horizon),
            control1: CGPoint(x: size.width * 0.26, y: horizon - size.height * 0.025),
            control2: CGPoint(x: size.width * 0.72, y: horizon + size.height * 0.008)
        )
        foreground.addLine(to: CGPoint(x: size.width, y: horizon + size.height * 0.02))
        foreground.addLine(to: CGPoint(x: 0, y: horizon + size.height * 0.02))
        foreground.closeSubpath()
        context.fill(foreground, with: .color(palette.land.opacity(0.9)))
    }

    private func drawWater(context: inout GraphicsContext, size: CGSize, horizon: CGFloat) {
        let waterRect = CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)
        context.fill(
            Path(waterRect),
            with: .linearGradient(
                Gradient(colors: [palette.waterTop, palette.waterBottom]),
                startPoint: CGPoint(x: 0, y: horizon),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        for index in 0..<14 {
            let fraction = CGFloat(index) / 14
            let y = horizon + fraction * (size.height - horizon) * 0.92
            let inset = size.width * (0.04 + 0.34 * fraction)
            let width = size.width * (0.10 + 0.22 * abs(sin(Double(index) * 1.7)))
            let rect = CGRect(
                x: inset,
                y: y,
                width: width,
                height: 0.7
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 0.35),
                with: .color(Color.white.opacity(0.05 + 0.05 * abs(sin(Double(index) * 2.3))))
            )
        }
    }

    private func drawFog(context: inout GraphicsContext, size: CGSize, horizon: CGFloat) {
        let bandRect = CGRect(
            x: 0,
            y: horizon - size.height * 0.10,
            width: size.width,
            height: size.height * 0.16
        )
        context.fill(
            Path(bandRect),
            with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.07),
                    Color.white.opacity(0.0)
                ]),
                startPoint: CGPoint(x: 0, y: bandRect.minY),
                endPoint: CGPoint(x: 0, y: bandRect.maxY)
            )
        )
    }

    private func drawBoat(context: inout GraphicsContext, size: CGSize, horizon: CGFloat) {
        let boatWidth = size.width * 0.072
        let boatHeight = boatWidth * 0.42
        let originX = size.width * palette.boatX
        let originY = horizon + size.height * 0.10

        var hull = Path()
        hull.move(to: CGPoint(x: originX - boatWidth / 2, y: originY))
        hull.addLine(to: CGPoint(x: originX + boatWidth / 2, y: originY))
        hull.addCurve(
            to: CGPoint(x: originX, y: originY + boatHeight),
            control1: CGPoint(x: originX + boatWidth * 0.34, y: originY + boatHeight * 0.55),
            control2: CGPoint(x: originX + boatWidth * 0.12, y: originY + boatHeight)
        )
        hull.addCurve(
            to: CGPoint(x: originX - boatWidth / 2, y: originY),
            control1: CGPoint(x: originX - boatWidth * 0.16, y: originY + boatHeight),
            control2: CGPoint(x: originX - boatWidth * 0.36, y: originY + boatHeight * 0.4)
        )
        hull.closeSubpath()
        context.fill(hull, with: .color(palette.land.opacity(0.95)))

        var mast = Path()
        mast.move(to: CGPoint(x: originX, y: originY))
        mast.addLine(to: CGPoint(x: originX, y: originY - boatHeight * 2.2))
        context.stroke(mast, with: .color(palette.land.opacity(0.9)), lineWidth: max(0.7, boatWidth * 0.025))

        var sail = Path()
        sail.move(to: CGPoint(x: originX, y: originY - boatHeight * 2.1))
        sail.addLine(to: CGPoint(x: originX - boatWidth * 0.42, y: originY - boatHeight * 0.18))
        sail.addLine(to: CGPoint(x: originX, y: originY - boatHeight * 0.18))
        sail.closeSubpath()
        context.fill(sail, with: .color(palette.land.opacity(0.72)))
    }

    private func drawVignette(context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [
                    Color.clear,
                    Color.black.opacity(0.08)
                ]),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: min(size.width, size.height) * 0.3,
                endRadius: max(size.width, size.height) * 0.75
            )
        )
    }
}

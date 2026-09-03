import AppKit
import QuartzCore

@MainActor
final class AuroraView: NSView {
    private struct Strand {
        let color: CGColor
        let frequency: CGFloat
        let amplitude: CGFloat
        let width: CGFloat
        let phase: CGFloat
    }

    private struct BlendState {
        var wave: CGFloat = 1
        var orbit: CGFloat = 0
        var sweep: CGFloat = 0
        var sweepTime: CGFloat = 0
    }

    private struct Target {
        let wave: CGFloat
        let orbit: CGFloat
        let sweep: CGFloat
    }

    private static let responsiveness: CGFloat = 0.6
    private static let glow: CGFloat = 0.7
    private static let orbitGlow: CGFloat = 0.9
    private static let orbitRadiusSpread: CGFloat = 0.28
    private static let retinaScale: CGFloat = 0.5

    private static let strands = [
        Strand(color: color("#FFB347"), frequency: 1.0, amplitude: 0.55, width: 1.2, phase: 0.0),
        Strand(color: color("#FF5E8A"), frequency: 1.35, amplitude: 0.8, width: 1.4, phase: 1.1),
        Strand(color: color("#C64BFF"), frequency: 1.7, amplitude: 1.0, width: 1.6, phase: 2.3),
        Strand(color: color("#6B5BFF"), frequency: 2.1, amplitude: 0.75, width: 1.3, phase: 3.4),
        Strand(color: color("#3FD6FF"), frequency: 2.6, amplitude: 0.5, width: 1.1, phase: 4.6),
    ]

    private var animationTimer: Timer?
    private var lastFrameTime: CFTimeInterval?
    private var state: HUDState = .listening
    private var blend = BlendState()
    private var targetLevel: CGFloat = 0
    private var smoothedLevel: CGFloat = 0
    private var phase: CGFloat = 0
    private var drift: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 64, height: 14)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func setLevel(_ rms: Float) {
        targetLevel = CGFloat(min(1, max(0, rms)))
        if reducesMotion {
            smoothedLevel = targetLevel
            needsDisplay = true
        }
    }

    func setState(_ state: HUDState) {
        self.state = state
        if state != .listening {
            targetLevel = 0
        }
        if reducesMotion {
            applyStaticPose()
        }
        needsDisplay = true
    }

    func startAnimating() {
        guard animationTimer == nil else {
            return
        }
        guard !reducesMotion else {
            applyStaticPose()
            needsDisplay = true
            return
        }

        lastFrameTime = CACurrentMediaTime()
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(displayFrame),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        lastFrameTime = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            !bounds.isEmpty,
            let context = NSGraphicsContext.current?.cgContext
        else {
            return
        }

        context.clear(bounds)
        drawStrands(in: context)
    }

    @objc
    private func displayFrame() {
        guard window?.isVisible == true, !isHidden else {
            lastFrameTime = CACurrentMediaTime()
            return
        }

        let now = CACurrentMediaTime()
        let delta = min(0.05, now - (lastFrameTime ?? now))
        lastFrameTime = now
        advance(by: CGFloat(delta))
        needsDisplay = true
    }

    private func advance(by delta: CGFloat) {
        let attack = 12 + Self.responsiveness * 40
        let release = 3 + Self.responsiveness * 9
        let smoothingRate = targetLevel > smoothedLevel ? attack : release
        smoothedLevel = ease(
            smoothedLevel,
            toward: targetLevel,
            delta: delta,
            rate: smoothingRate
        )

        let target = target(for: state)
        blend.wave = ease(blend.wave, toward: target.wave, delta: delta, rate: 9)
        blend.orbit = ease(blend.orbit, toward: target.orbit, delta: delta, rate: 5)
        blend.sweep = ease(blend.sweep, toward: target.sweep, delta: delta, rate: 6)
        blend.sweepTime = (blend.sweepTime + delta / 0.7).truncatingRemainder(dividingBy: 1)

        phase += delta
            * (2.5 + smoothedLevel * 9)
            * (0.3 + 0.7 * blend.wave)
            + delta * 2.6 * blend.orbit
        drift += delta
    }

    private func drawStrands(in context: CGContext) {
        let width = bounds.width
        let height = bounds.height
        let middle = height / 2
        let padding = width * 0.06
        let span = width - padding * 2
        let radius = height * 0.34
        let centerX = width / 2
        let orbit = blend.orbit
        let amplitude = max(0.05, smoothedLevel) * blend.wave
        let strandCount = Self.strands.count

        context.saveGState()
        context.setBlendMode(.plusLighter)

        for (index, strand) in Self.strands.enumerated() {
            let strandIndex = CGFloat(index)
            let radiusPosition = strandIndex / CGFloat(strandCount - 1)
            let strandRadius = radius * (
                1 - Self.orbitRadiusSpread / 2
                    + Self.orbitRadiusSpread * radiusPosition
            )
            let path = CGMutablePath()
            var x: CGFloat = 0
            var isFirstPoint = true

            while x <= span {
                let progress = x / span
                let window = sin(.pi * progress)
                let strandPhase = phase * (
                    0.7 + 0.3 * strandIndex / CGFloat(strandCount)
                ) + strand.phase
                let wave = sin(
                    progress * .pi * 2 * strand.frequency + strandPhase
                )
                let lineX = padding + x
                let lineY = middle
                    + wave * window * amplitude * strand.amplitude * (height * 0.46)

                let angle = progress * .pi * 2 + phase * 0.9 + strand.phase
                let wobble = 1 + 0.10 * sin(
                    progress * .pi * 6 + phase * 1.5 + strandIndex
                )
                let orbitX = centerX + cos(angle) * strandRadius * wobble
                let orbitY = middle + sin(angle) * strandRadius * wobble
                let point = CGPoint(
                    x: lineX + (orbitX - lineX) * orbit,
                    y: lineY + (orbitY - lineY) * orbit
                )

                if isFirstPoint {
                    path.move(to: point)
                    isFirstPoint = false
                } else {
                    path.addLine(to: point)
                }
                x += Self.retinaScale
            }

            let glowAmount = (0.4 + amplitude) * (1 - orbit)
                + Self.orbitGlow
                    * (0.6 + 0.4 * sin(drift * 2 + strandIndex))
                    * orbit
            stroke(
                path,
                strand: strand,
                glowAmount: glowAmount,
                coreAlpha: 1 - orbit,
                in: context
            )
        }

        if blend.sweep > 0.02 {
            drawSweep(
                in: context,
                middle: middle,
                padding: padding,
                span: span
            )
        }

        context.restoreGState()
    }

    private func stroke(
        _ path: CGPath,
        strand: Strand,
        glowAmount: CGFloat,
        coreAlpha: CGFloat,
        in context: CGContext
    ) {
        context.addPath(path)
        context.setStrokeColor(strand.color)
        context.setLineWidth(strand.width * Self.retinaScale)
        context.setLineCap(.round)
        context.setShadow(
            offset: .zero,
            blur: (2 + Self.glow * 10) * Self.retinaScale * glowAmount,
            color: strand.color
        )
        context.setAlpha(0.85)
        context.strokePath()

        guard coreAlpha > 0.02 else {
            return
        }

        context.addPath(path)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setLineWidth(
            max(0.6 * Self.retinaScale, strand.width * Self.retinaScale * 0.45)
        )
        context.setAlpha(0.95 * coreAlpha)
        context.strokePath()
    }

    private func drawSweep(
        in context: CGContext,
        middle: CGFloat,
        padding: CGFloat,
        span: CGFloat
    ) {
        let sweepWidth: CGFloat = 0.18
        let head = blend.sweepTime * (1 + sweepWidth) - sweepWidth
        let strandCount = Self.strands.count

        for (index, strand) in Self.strands.enumerated() {
            let strandProgress = CGFloat(index) / CGFloat(strandCount)
            let start = max(
                0,
                head - sweepWidth * (1 - strandProgress) * 0.6
            )
            let end = min(1, head + sweepWidth * 0.35)
            guard end > start else {
                continue
            }

            let path = CGMutablePath()
            path.move(to: CGPoint(x: padding + start * span, y: middle))
            path.addLine(to: CGPoint(x: padding + end * span, y: middle))
            context.addPath(path)
            context.setStrokeColor(strand.color)
            context.setLineCap(.round)
            context.setLineWidth(strand.width * 1.6 * Self.retinaScale)
            context.setShadow(
                offset: .zero,
                blur: (6 + Self.glow * 14) * Self.retinaScale,
                color: strand.color
            )
            context.setAlpha(0.9 * blend.sweep * (1 - blend.orbit))
            context.strokePath()
        }
    }

    private func applyStaticPose() {
        let target = target(for: state)
        blend.wave = target.wave
        blend.orbit = target.orbit
        blend.sweep = target.sweep
        blend.sweepTime = 0.5
        smoothedLevel = targetLevel
        phase = 0
        drift = 0
    }

    private func target(for state: HUDState) -> Target {
        switch state {
        case .listening:
            Target(wave: 1, orbit: 0, sweep: 0)
        case .transcribing:
            Target(wave: 0, orbit: 0, sweep: 1)
        case .cleaning:
            Target(wave: 0, orbit: 1, sweep: 0)
        case .done, .cleanedLocally:
            Target(wave: 0, orbit: 0, sweep: 0)
        }
    }

    private func ease(
        _ value: CGFloat,
        toward target: CGFloat,
        delta: CGFloat,
        rate: CGFloat
    ) -> CGFloat {
        value + (target - value) * min(1, rate * delta)
    }

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static func color(_ hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        ).cgColor
    }
}

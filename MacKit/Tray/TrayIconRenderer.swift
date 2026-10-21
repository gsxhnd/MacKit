//
//  TrayIconRenderer.swift
//  MacKit
//
//  菜单栏托盘图标渲染器：在 120×120 的画布上自绘
//  「电池圆环 + 网络符号 + 音量指示」组合图标。
//
//  绘制管线与几何参数移植自 lingyired/status-trio（Apache-2.0）的
//  StatusIconRenderer / StatusIconGeometry，并针对 MacKit 做了精简：
//  去掉充电动画、Dock 图标与分图元缓存，保留圆环、顶部缺口指示器、
//  中心 SF Symbol 与底部圆点/弧线。
//

import AppKit
import CoreText

enum TrayIconRenderer {
    // MARK: - 对外常量

    /// 画布边长（内部设计坐标）。
    static let canvasSize: CGFloat = 120

    /// 菜单栏图标默认点尺寸。
    static let defaultImageSize: CGFloat = 24

    /// 顶部缺口百分比文字的默认缩放。
    static let defaultTextScale: Double = 1.8

    // MARK: - 几何常量（120 画布，y 向下）

    private static let artworkCenterX: CGFloat = 59.5
    private static let ringCenter = CGPoint(x: artworkCenterX, y: 61.48715261785473)
    private static let ringRadius: CGFloat = 51.5
    private static let ringStart: CGFloat = 148.69008689281117 * .pi / 180
    private static let ringSweep: CGFloat = 242.6198262143777 * .pi / 180
    private static let ringValueGapWidth: CGFloat = 64
    private static let ringIndicatorGapWidth: CGFloat = 50
    private static let ringLineWidth: CGFloat = 8
    private static let inactiveTrackAlpha: CGFloat = 0.22

    private static let centerSymbolPointSize: CGFloat = 42
    private static let centerPoint = CGPoint(x: artworkCenterX, y: 64.0)

    private static let valueBaseFontSize: CGFloat = 20
    private static let boltTipPivot = CGPoint(x: artworkCenterX, y: 2.1)
    private static let boltHeightCalibration: CGFloat = 220.0 / 180.0

    private static let volumeDotPoints: [CGPoint] = [
        CGPoint(x: 33, y: 104.2),
        CGPoint(x: 50.5, y: 111.2),
        CGPoint(x: 68.5, y: 111.7),
        CGPoint(x: 86, y: 105.8)
    ]
    private static let volumeDotRadius: CGFloat = 5.5
    private static let volumeArcStart: CGFloat = 121.82 * .pi / 180
    private static let volumeArcEnd: CGFloat = 59.12 * .pi / 180
    private static let volumeArcLineWidth: CGFloat = 7

    // MARK: - 入口

    /// 生成可直接挂到 NSStatusItem 上的图像。
    ///
    /// 纯单色场景会标记为 template image，交给系统按当前 Space 的
    /// 菜单栏明暗实时着色（与 status-trio 的 template 方案一致）；
    /// 带状态色（低电量 / 低电量模式 / 充电）时才使用彩色位图。
    static func image(
        scene: TrayIconScene,
        size: CGFloat = defaultImageSize,
        appearance: NSAppearance? = nil
    ) -> NSImage {
        let dimension = size.isFinite && size > 0 ? size : defaultImageSize

        // 位图输出：macOS 26 的状态项由 Control Center 跨进程渲染，
        // lazy drawing-handler 图片在那里可能无法正确呈现。
        let pixelScale: CGFloat = 2
        let pixelLength = Int((dimension * pixelScale).rounded(.up))
        guard pixelLength > 0,
              pixelLength <= 4096,
              let context = CGContext(
                  data: nil,
                  width: pixelLength,
                  height: pixelLength,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelLength * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return NSImage(size: NSSize(width: dimension, height: dimension))
        }

        context.scaleBy(x: pixelScale, y: pixelScale)

        // 颜色在创建时固化，必须按菜单栏当前外观解析（明暗自适应）。
        let drawScene = { draw(scene: scene, in: context, size: dimension) }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(drawScene)
        } else {
            drawScene()
        }

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: dimension, height: dimension))
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: dimension, height: dimension))
        image.isTemplate = scene.usesOnlyMonochromeRoles
        return image
    }

    // MARK: - 绘制主流程

    private static func draw(scene: TrayIconScene, in context: CGContext, size: CGFloat) {
        let scale = size / canvasSize
        context.saveGState()
        defer { context.restoreGState() }

        context.translateBy(x: 0, y: size)
        context.scaleBy(x: scale, y: -scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if let ring = scene.outerRing {
            drawRing(ring, in: context)
        }
        if let center = scene.center {
            drawCenter(center, in: context)
        }
        if let footer = scene.footer {
            drawFooter(footer, in: context)
        }
    }

    // MARK: - 顶部圆环

    private static func drawRing(_ ring: TrayOuterRing, in context: CGContext) {
        guard let segment = ring.segments.first else { return }

        let hasGap = ring.gap != .closed
        let gapWidth = ring.gap == .value ? ringValueGapWidth : ringIndicatorGapWidth
        let lineWidth = ringLineWidth * CGFloat(ring.strokeScale)
        let arcColor = color(for: segment.color)

        // 未填充轨道
        context.setLineWidth(lineWidth)
        context.setStrokeColor(inactiveColor())
        context.addPath(ringTrackPath(hasGap: hasGap, gapWidth: gapWidth))
        context.strokePath()

        // 进度填充
        if segment.progress > 0 {
            context.setLineWidth(lineWidth)
            context.setStrokeColor(arcColor)
            context.addPath(ringFillPath(progress: segment.progress, hasGap: hasGap, gapWidth: gapWidth))
            context.strokePath()
        }

        // 顶部缺口指示器
        if let accessory = ring.accessory {
            drawRingAccessory(accessory, in: context)
        }
    }

    private static func drawRingAccessory(_ accessory: TrayRingAccessory, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShadow(offset: CGSize(width: 0, height: 0.75), blur: 0.75,
                          color: CGColor(gray: 0, alpha: 0.38))

        switch accessory {
        case let .text(text):
            let fontSize = valueBaseFontSize * CGFloat(text.scale)
            drawText(
                text.text,
                color: color(for: text.color),
                fontSize: fontSize,
                baseline: CGPoint(x: artworkCenterX, y: valueBaseline(fontSize: fontSize)),
                in: context
            )
        case let .symbol(symbol):
            let boltScale = chargingBoltScale(textScale: symbol.scale)
            if symbol.symbolNames.isEmpty {
                // 内置 bolt 图元（充电中）
                context.setFillColor(color(for: symbol.color))
                context.addPath(boltPath(scale: boltScale))
                context.fillPath()
            } else {
                // SF Symbol（插电未充电的插头）
                drawSymbol(
                    symbol,
                    pointSize: plugPointSize(for: symbol, boltScale: boltScale),
                    center: topIndicatorCenter(boltScale: boltScale),
                    in: context
                )
            }
        }
    }

    // MARK: - 中心符号

    private static func drawCenter(_ center: TrayCenter, in context: CGContext) {
        switch center {
        case let .symbol(symbol):
            drawSymbol(
                symbol,
                pointSize: centerSymbolPointSize * CGFloat(symbol.scale),
                center: centerPoint,
                in: context
            )
        case let .text(text):
            let fontSize = centerSymbolPointSize * CGFloat(text.scale)
            drawText(
                text.text,
                color: color(for: text.color),
                fontSize: fontSize,
                baseline: CGPoint(x: artworkCenterX, y: centerPoint.y + fontSize * 0.36),
                in: context
            )
        }
    }

    // MARK: - 底部（风扇）

    private static func drawFooter(_ footer: TrayFooter, in context: CGContext) {
        switch footer {
        case let .dots(dots):
            let active = color(for: dots.color)
            let inactive = inactiveColor()
            for (index, point) in volumeDotPoints.prefix(dots.count).enumerated() {
                context.setFillColor(index < dots.activeCount ? active : inactive)
                context.fillEllipse(in: CGRect(
                    x: point.x - volumeDotRadius,
                    y: point.y - volumeDotRadius,
                    width: volumeDotRadius * 2,
                    height: volumeDotRadius * 2
                ))
            }
        case let .arc(arc):
            let lineWidth = volumeArcLineWidth * CGFloat(arc.strokeScale)
            context.setLineWidth(lineWidth)
            context.setStrokeColor(inactiveColor())
            context.addPath(volumeArcTrackPath())
            context.strokePath()

            guard arc.progress > 0 else { return }
            context.setLineWidth(lineWidth)
            context.setStrokeColor(color(for: arc.color))
            context.addPath(volumeArcFillPath(progress: arc.progress))
            context.strokePath()
        }
    }

    // MARK: - 颜色解析

    /// 按当前绘制外观（菜单栏明暗）解析颜色角色。
    private static func color(for role: TrayIconColorRole) -> CGColor {
        switch role {
        case .primary:
            return labelColor()
        case .inactive:
            return inactiveColor()
        case .critical:
            return (NSColor.systemRed.usingColorSpace(.deviceRGB) ?? .systemRed).cgColor
        case .lowPower:
            return usesDarkLabel() ? cgColor(201, 151, 0) : cgColor(242, 185, 0)
        case .powered:
            return usesDarkLabel() ? cgColor(31, 143, 61) : cgColor(52, 199, 89)
        case .bluetooth:
            // 与 status-trio 一致：浅色菜单栏用深蓝，深色菜单栏用亮蓝。
            return usesDarkLabel() ? cgColor(0, 102, 204) : cgColor(77, 163, 255)
        }
    }

    private static func labelColor() -> CGColor {
        (NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor).cgColor
    }

    private static func inactiveColor() -> CGColor {
        labelColor().copy(alpha: inactiveTrackAlpha) ?? labelColor()
    }

    /// 菜单栏前景色偏暗 = 浅色菜单栏。
    private static func usesDarkLabel() -> Bool {
        guard let color = NSColor(cgColor: labelColor())?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return color.brightnessComponent < 0.5
    }

    private static func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    // MARK: - 路径

    private static func ringTrackPath(hasGap: Bool, gapWidth: CGFloat) -> CGPath {
        ringArcPath(from: 0, to: 1, hasGap: hasGap, gapWidth: gapWidth)
    }

    private static func ringFillPath(progress: Double, hasGap: Bool, gapWidth: CGFloat) -> CGPath {
        ringArcPath(from: 0, to: progress, hasGap: hasGap, gapWidth: gapWidth)
    }

    /// 按进度切出圆环弧段；顶部缺口（进度 0.5 附近）会被挖掉。
    private static func ringArcPath(from start: Double, to end: Double, hasGap: Bool, gapWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard start.isFinite, end.isFinite, end > start else { return path }
        let clampedStart = min(1, max(0, start))
        let clampedEnd = min(1, max(0, end))
        guard clampedEnd > clampedStart else { return path }

        if !hasGap {
            path.addArc(
                center: ringCenter,
                radius: ringRadius,
                startAngle: ringStart + ringSweep * CGFloat(clampedStart),
                endAngle: ringStart + ringSweep * CGFloat(clampedEnd),
                clockwise: false
            )
            return path
        }

        let arcLength = ringRadius * ringSweep
        let gapFraction = arcLength > 0 ? min(1, gapWidth / arcLength) : 0
        let gapStart = (1 - gapFraction) / 2
        let gapEnd = gapStart + gapFraction

        let firstEnd = min(clampedEnd, gapStart)
        if firstEnd > clampedStart {
            path.addArc(
                center: ringCenter,
                radius: ringRadius,
                startAngle: ringStart + ringSweep * CGFloat(clampedStart),
                endAngle: ringStart + ringSweep * CGFloat(firstEnd),
                clockwise: false
            )
        }
        let secondStart = max(clampedStart, gapEnd)
        if clampedEnd > secondStart {
            path.addArc(
                center: ringCenter,
                radius: ringRadius,
                startAngle: ringStart + ringSweep * CGFloat(secondStart),
                endAngle: ringStart + ringSweep * CGFloat(clampedEnd),
                clockwise: false
            )
        }
        return path
    }

    /// 充电闪电，绕顶部顶点缩放。
    private static func boltPath(scale: CGFloat = 1) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 62.1, y: 2.2))
        path.addQuadCurve(to: CGPoint(x: 62.6, y: 3.3), control: CGPoint(x: 62.8, y: 2.5))
        path.addLine(to: CGPoint(x: 61.2, y: 7.8))
        path.addLine(to: CGPoint(x: 65.9, y: 7.8))
        path.addQuadCurve(to: CGPoint(x: 67.3, y: 8.6), control: CGPoint(x: 66.9, y: 7.8))
        path.addQuadCurve(to: CGPoint(x: 67.0, y: 10.0), control: CGPoint(x: 67.6, y: 9.3))
        path.addLine(to: CGPoint(x: 57.0, y: 21.3))
        path.addQuadCurve(to: CGPoint(x: 55.6, y: 21.6), control: CGPoint(x: 56.4, y: 22.0))
        path.addQuadCurve(to: CGPoint(x: 55.3, y: 20.5), control: CGPoint(x: 55.0, y: 21.3))
        path.addLine(to: CGPoint(x: 57.4, y: 14.1))
        path.addLine(to: CGPoint(x: 52.9, y: 14.1))
        path.addQuadCurve(to: CGPoint(x: 51.6, y: 13.3), control: CGPoint(x: 52.0, y: 14.1))
        path.addQuadCurve(to: CGPoint(x: 51.9, y: 12.0), control: CGPoint(x: 51.3, y: 12.6))
        path.addLine(to: CGPoint(x: 61.1, y: 2.7))
        path.addQuadCurve(to: CGPoint(x: 62.1, y: 2.2), control: CGPoint(x: 61.6, y: 2.1))
        path.closeSubpath()

        guard scale.isFinite, scale > 0, scale != 1 else { return path }
        let pivot = boltTipPivot
        var transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: pivot.x * (1 - scale),
            ty: pivot.y * (1 - scale)
        )
        return path.copy(using: &transform) ?? path
    }

    private static func volumeArcTrackPath() -> CGPath {
        let path = CGMutablePath()
        path.addArc(
            center: ringCenter,
            radius: ringRadius,
            startAngle: volumeArcStart,
            endAngle: volumeArcEnd,
            clockwise: true
        )
        return path
    }

    private static func volumeArcFillPath(progress: Double) -> CGPath {
        let clamped = min(1, max(0, progress))
        guard clamped > 0 else { return CGMutablePath() }
        let sweep = volumeArcStart - volumeArcEnd
        let end = volumeArcStart - sweep * CGFloat(clamped)
        let path = CGMutablePath()
        path.addArc(
            center: ringCenter,
            radius: ringRadius,
            startAngle: volumeArcStart,
            endAngle: end,
            clockwise: true
        )
        return path
    }

    // MARK: - 顶部指示器尺寸

    /// 顶部指示器与百分比数字同高，保证换符号时视觉重心一致。
    private static func chargingBoltScale(textScale: Double) -> CGFloat {
        let boltBounds = boltPath().boundingBoxOfPath
        let boltHeight = boltBounds.height
        guard boltHeight > 0 else { return 1 }

        let targetHeight = topIndicatorHeight(textScale: textScale, boltHeight: boltHeight)
        guard targetHeight > 0 else {
            return CGFloat(textScale / defaultTextScale) * boltHeightCalibration
        }
        return targetHeight / boltHeight
    }

    private static func topIndicatorHeight(textScale: Double, boltHeight: CGFloat) -> CGFloat {
        let fontSize = valueBaseFontSize * CGFloat(textScale)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "100",
            attributes: [.font: valueFont(size: fontSize)]
        ))
        let glyphHeight = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).height
        guard glyphHeight.isFinite, glyphHeight > 0 else {
            return boltHeight * CGFloat(textScale / defaultTextScale) * boltHeightCalibration
        }
        return glyphHeight
    }

    /// 插头比 bolt 细，按 1.2 倍墨迹高度补偿视觉重量。
    /// 先用参考字号测量墨迹高度，再换算出准确字号，避免不同符号图片框留白差异。
    private static func plugPointSize(for symbol: TrayIconSymbolState, boltScale: CGFloat) -> CGFloat {
        let boltHeight = boltPath().boundingBoxOfPath.height
        guard boltHeight > 0 else { return 38 }
        let targetHeight = boltHeight * boltScale * 1.2
        let referencePointSize: CGFloat = 100
        guard let probe = configuredSymbolImage(
            symbol,
            pointSize: referencePointSize,
            tint: labelColor()
        ) else {
            return 38
        }
        let ink = SymbolInkCache.shared.inkRect(
            name: symbol.symbolNames.first ?? "",
            variableValue: symbol.variableValue,
            pointSize: Double(referencePointSize)
        ) {
            measureInk(of: probe)
        }
        guard ink.height > 0 else { return 38 }
        let pointSize = targetHeight * referencePointSize / ink.height
        return pointSize.isFinite && pointSize > 0 ? pointSize : 38
    }

    /// bolt 缩放后顶部指示器的视觉中心。
    private static func topIndicatorCenter(boltScale: CGFloat) -> CGPoint {
        let bounds = boltPath().boundingBoxOfPath
        let pivot = boltTipPivot
        return CGPoint(
            x: pivot.x + (bounds.midX - pivot.x) * boltScale,
            y: pivot.y + (bounds.midY - pivot.y) * boltScale
        )
    }

    private static func valueBaseline(fontSize: CGFloat) -> CGFloat {
        let referenceFontSize: CGFloat = 20
        let referenceBaseline: CGFloat = 17
        let currentFontSize: CGFloat = 32
        let currentBaseline: CGFloat = 24
        let slope = (currentBaseline - referenceBaseline) / (currentFontSize - referenceFontSize)
        return referenceBaseline + (fontSize - referenceFontSize) * slope
    }

    private static func valueFont(size: CGFloat) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let descriptor = fallback.fontDescriptor.withDesign(.rounded) else {
            return fallback
        }
        return NSFont(descriptor: descriptor, size: size) ?? fallback
    }

    // MARK: - 文字

    private static func drawText(
        _ text: String,
        color: CGColor,
        fontSize: CGFloat,
        baseline: CGPoint,
        in context: CGContext
    ) {
        let font = valueFont(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: -fontSize * 0.04,
            .foregroundColor: NSColor(cgColor: color) ?? .white
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        context.setFillColor(color)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: baseline.x - width / 2, y: baseline.y)
        CTLineDraw(line, context)
    }

    // MARK: - SF Symbol

    private static func drawSymbol(
        _ symbol: TrayIconSymbolState,
        pointSize: CGFloat,
        center: CGPoint,
        in context: CGContext
    ) {
        let tint = color(for: symbol.color)
        guard let image = configuredSymbolImage(symbol, pointSize: pointSize, tint: tint) else {
            return
        }

        // 以可见墨迹中心对齐目标点，而不是图片框中心。
        let ink = SymbolInkCache.shared.inkRect(
            name: symbol.symbolNames.first ?? "",
            variableValue: symbol.variableValue,
            pointSize: Double(pointSize)
        ) {
            measureInk(of: image)
        }

        context.saveGState()
        defer { context.restoreGState() }

        let gc = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = gc

        context.scaleBy(x: 1, y: -1)

        let targetRect = CGRect(
            x: center.x - ink.midX,
            y: -(center.y + ink.midY),
            width: image.size.width,
            height: image.size.height
        )
        image.draw(in: targetRect)
    }

    private static func configuredSymbolImage(
        _ symbol: TrayIconSymbolState,
        pointSize: CGFloat,
        tint: CGColor
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(hierarchicalColor: NSColor(cgColor: tint) ?? .labelColor))
        guard let base = symbolImage(symbol) else { return nil }
        return base.withSymbolConfiguration(config)
    }

    private static func symbolImage(_ symbol: TrayIconSymbolState) -> NSImage? {
        for name in symbol.symbolNames {
            if let variableValue = symbol.variableValue,
               let image = NSImage(systemSymbolName: name, variableValue: variableValue, accessibilityDescription: nil) {
                return image
            }
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return image
            }
        }
        return nil
    }

    /// 符号可见墨迹的包围盒（图片局部坐标，y 向上、原点在图片左下角）。
    private static func measureInk(of image: NSImage) -> CGRect {
        let pixelScale: CGFloat = 8
        let width = Int((image.size.width * pixelScale).rounded(.up))
        let height = Int((image.size.height * pixelScale).rounded(.up))
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = context.data else {
            return CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width
        var maxX = -1
        var minRow = height
        var maxRow = -1
        for row in 0..<height {
            for column in 0..<width where buffer[(row * width + column) * 4 + 3] > 8 {
                if column < minX { minX = column }
                if column > maxX { maxX = column }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
        guard maxX >= minX, maxRow >= minRow else {
            return CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        }

        // 位图缓冲第 0 行是图片顶部；换算成 y 向上的图片局部坐标。
        let top = CGFloat(height - minRow) / pixelScale
        let bottom = CGFloat(height - (maxRow + 1)) / pixelScale
        return CGRect(
            x: CGFloat(minX) / pixelScale,
            y: bottom,
            width: CGFloat(maxX - minX + 1) / pixelScale,
            height: max(0, top - bottom)
        )
    }
}

// MARK: - 墨迹缓存

/// SF Symbol 的墨迹测量需要离屏光栅化，按（名称, 可变值, 字号）缓存。
private final class SymbolInkCache: @unchecked Sendable {
    static let shared = SymbolInkCache()

    private struct Key: Hashable {
        let name: String
        let variableValue: Double?
        let pointSize: Double
    }

    private let lock = NSLock()
    private var storage: [Key: CGRect] = [:]
    private var order: [Key] = []

    func inkRect(name: String, variableValue: Double?, pointSize: Double, measure: () -> CGRect) -> CGRect {
        let key = Key(name: name, variableValue: variableValue, pointSize: pointSize)
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[key] {
            return cached
        }
        let measured = measure()
        storage[key] = measured
        order.append(key)
        if order.count > 256 {
            storage[order.removeFirst()] = nil
        }
        return measured
    }
}

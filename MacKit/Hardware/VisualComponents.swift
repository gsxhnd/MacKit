//
//  VisualComponents.swift
//  MacKit
//
//  仪表盘视觉组件：动态背景、玻璃卡片、趋势线与温度仪表。
//

import SwiftUI

// MARK: - 动态极光背景

struct AuroraBackground: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10.0)) { timeline in
            let time = Float(timeline.date.timeIntervalSinceReferenceDate)
            GeometryReader { proxy in
                let wobble = sin(time * 0.18)
                let wobble2 = cos(time * 0.13)
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        SIMD2<Float>(0, 0),
                        SIMD2<Float>(0.5 + 0.08 * wobble, 0),
                        SIMD2<Float>(1, 0),
                        SIMD2<Float>(0, 0.5 + 0.06 * wobble2),
                        SIMD2<Float>(0.5 + 0.12 * wobble2, 0.5 + 0.08 * wobble),
                        SIMD2<Float>(1, 0.5 + 0.05 * wobble),
                        SIMD2<Float>(0, 1),
                        SIMD2<Float>(0.5 - 0.08 * wobble, 1),
                        SIMD2<Float>(1, 1)
                    ],
                    colors: [
                        tint.opacity(0.55),
                        tint.opacity(0.18),
                        Color.blue.opacity(0.28),
                        Color.purple.opacity(0.22),
                        tint.opacity(0.40),
                        Color.teal.opacity(0.22),
                        Color.indigo.opacity(0.30),
                        tint.opacity(0.16),
                        Color.orange.opacity(0.18)
                    ]
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .opacity(0.62)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.04),
                    Color(nsColor: .windowBackgroundColor).opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 颜色

func temperatureTint(_ value: Double) -> Color {
    switch value {
    case ..<35: .cyan
    case 35..<50: .green
    case 50..<65: .yellow
    case 65..<78: .orange
    case 78..<92: .red
    default: Color(red: 0.85, green: 0.15, blue: 0.25)
    }
}

func temperatureDescription(_ value: Double) -> String {
    switch value {
    case ..<35: "凉爽"
    case 35..<50: "舒适"
    case 50..<65: "温热"
    case 65..<78: "较热"
    case 78..<92: "高温"
    default: "过热"
    }
}

func batteryStateTint(_ state: BatteryPowerState) -> Color {
    state.tint
}

// MARK: - 趋势线

struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var showsBaseline = true

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }

            let minimum = values.min() ?? 0
            let maximum = values.max() ?? 1
            let spread = max(maximum - minimum, 0.5)
            let stepX = size.width / CGFloat(values.count - 1)

            var points: [CGPoint] = []
            points.reserveCapacity(values.count)
            for (index, value) in values.enumerated() {
                let normalized = (value - minimum) / spread
                let y = size.height - CGFloat(normalized) * (size.height - 8) - 4
                points.append(CGPoint(x: CGFloat(index) * stepX, y: y))
            }

            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() {
                line.addLine(to: point)
            }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            if showsBaseline {
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.32), color.opacity(0.015)]),
                        startPoint: .init(x: 0, y: 0),
                        endPoint: .init(x: 0, y: size.height)
                    )
                )
            }

            context.addFilter(.shadow(color: color.opacity(0.65), radius: 5))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            context.addFilter(.shadow(color: .clear, radius: 0))
            context.stroke(line, with: .color(color.opacity(0.95)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

            if let last = points.last {
                context.fill(
                    Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                    with: .color(color)
                )
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

struct MetricSparkline: View {
    let title: String
    let value: String
    let subtitle: String?
    let values: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }

            ZStack {
                Sparkline(values: values, color: color)
                    .frame(height: 42)

                if values.count < 2 {
                    Text("正在采集…")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 42)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 温度仪表

struct TemperatureDial: View {
    let title: String
    let value: Double?
    var maximum: Double = 110
    var symbolName: String = "thermometer.medium"
    var size: CGFloat = 148

    private var current: Double { value ?? 0 }
    private var fraction: CGFloat {
        CGFloat(min(max(current / maximum, 0), 1))
    }

    var body: some View {
        let color = value.map(temperatureTint) ?? .secondary

        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(135))

                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.45), color, color.opacity(0.8)],
                            center: .center,
                            startAngle: .degrees(135),
                            endAngle: .degrees(405)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))
                    .shadow(color: color.opacity(0.55), radius: 8)
                    .animation(.smooth(duration: 0.45), value: fraction)

                Circle()
                    .fill(color.opacity(0.08))
                    .padding(20)

                VStack(spacing: 2) {
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color.opacity(0.85))

                    Text(value.map { String(format: "%.1f", $0) } ?? "--")
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.primary)

                    Text("°C")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: size, height: size)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if let value {
                Text(temperatureDescription(value))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color)
            }
        }
    }
}

// MARK: - 热区图

struct HeatmapView: View {
    let readings: [TemperatureReading]
    var columns = 6

    private func shortLabel(for reading: TemperatureReading) -> String {
        let suffix = String(reading.key.suffix(2))
        if reading.key.hasPrefix("Tp") { return "P\(suffix)" }
        if reading.key.hasPrefix("Te") { return "E\(suffix)" }
        if reading.key.hasPrefix("TRD") { return "G\(reading.key.suffix(1))" }
        if reading.key.hasPrefix("Tg") { return "G\(suffix)" }
        return suffix
    }

    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 5), count: columns)
    }

    var body: some View {
        LazyVGrid(columns: grid, spacing: 5) {
            ForEach(readings) { reading in
                let color = temperatureTint(reading.celsius)
                VStack(spacing: 1) {
                    Text(shortLabel(for: reading))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(Int(reading.celsius.rounded()))°")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(color.opacity(0.22), lineWidth: 0.8)
                )
                .help("\(reading.name) · \(reading.key) · \(reading.formatted)")
            }
        }
    }
}

struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("低")
            LinearGradient(
                colors: [.cyan, .green, .yellow, .orange, .red],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 4)
            .clipShape(Capsule())
            Text("高")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }
}

// MARK: - 风扇转速弧

struct FanTachometer: View {
    let fan: FanInfo
    var size: CGFloat = 82

    private var color: Color {
        switch fan.mode {
        case .manual: .orange
        case .auto, .system: .teal
        case .unknown: .secondary
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 7)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(144))
            Circle()
                .trim(from: 0, to: 0.7 * fan.fraction)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.4), color], center: .center, startAngle: .degrees(144), endAngle: .degrees(396)),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(144))
                .shadow(color: color.opacity(0.5), radius: 6)
                .animation(.smooth(duration: 0.5), value: fan.fraction)

            VStack(spacing: 1) {
                Text("\(Int((fan.actualRPM ?? 0).rounded()))")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("RPM")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 能量流

struct EnergyFlowView: View {
    let snapshot: BatterySnapshot

    private var stateTint: Color { snapshot.state.tint }

    var body: some View {
        HStack(spacing: 10) {
            FlowNode(
                title: "电源",
                value: snapshot.adapter?.watts.map { "\($0) W" } ?? (snapshot.externalConnected ? "已连接" : "未连接"),
                systemImage: "powerplug.fill",
                tint: .green,
                active: snapshot.externalConnected
            )

            FlowLine(
                color: .green,
                active: snapshot.externalConnected,
                reverse: false
            )

            FlowNode(
                title: "系统",
                value: BatteryFormat.watts(snapshot.power?.systemLoadW),
                systemImage: "laptopcomputer",
                tint: .blue,
                active: true
            )

            FlowLine(
                color: stateTint,
                active: snapshot.batteryPresent,
                reverse: (snapshot.powerW ?? 0) < 0
            )

            FlowNode(
                title: "电池",
                value: BatteryFormat.watts(snapshot.powerW, signed: true),
                systemImage: "battery.100",
                tint: stateTint,
                active: snapshot.batteryPresent
            )
        }
    }
}

private struct FlowNode: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    let active: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(tint.opacity(active ? 0.16 : 0.05))
                Circle()
                    .strokeBorder(tint.opacity(active ? 0.3 : 0.08), lineWidth: 1)
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? tint : Color.secondary.opacity(0.5))
            }
            .frame(width: 38, height: 38)
            .shadow(color: active ? tint.opacity(0.2) : .clear, radius: 8)

            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(width: 78)
    }
}

private struct FlowLine: View {
    let color: Color
    let active: Bool
    let reverse: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let y = size.height / 2
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    line,
                    with: .color(color.opacity(active ? 0.35 : 0.10)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 5])
                )

                guard active else { return }
                for index in 0..<3 {
                    let position = (time * 0.32 + Double(index) / 3.0).truncatingRemainder(dividingBy: 1)
                    let x = reverse ? size.width * (1 - position) : size.width * position
                    let dot = CGRect(x: x - 2, y: y - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                }
            }
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
    }
}

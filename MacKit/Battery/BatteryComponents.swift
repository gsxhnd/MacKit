//
//  BatteryComponents.swift
//  MacKit
//
//  仪表盘通用组件与菜单栏内容。
//

import AppKit
import SwiftUI

// MARK: - 状态配色

extension BatteryPowerState {
    var tint: Color {
        switch self {
        case .charging, .charged: .green
        case .pluggedNotCharging: .orange
        case .discharging: .blue
        case .critical: .red
        case .unavailable: Color(nsColor: .secondaryLabelColor)
        }
    }

    var symbolName: String {
        switch self {
        case .charging: "bolt.fill"
        case .charged: "checkmark.circle.fill"
        case .pluggedNotCharging: "powerplug.fill"
        case .discharging: "arrow.down.circle.fill"
        case .critical: "exclamationmark.triangle.fill"
        case .unavailable: "battery.0"
        }
    }
}

// MARK: - 卡片

struct DashboardCard<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let tint: Color
    private let content: Content
    @State private var hovered = false

    init(
        _ title: String,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.42))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.09), .clear, .primary.opacity(0.015)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.primary.opacity(0.10), tint.opacity(0.16), .primary.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(hovered ? 0.16 : 0.08), radius: hovered ? 16 : 9, y: hovered ? 7 : 3)
        .scaleEffect(hovered ? 1.004 : 1)
        .onHover { hovered = $0 }
        .animation(.smooth(duration: 0.22), value: hovered)
    }
}

// MARK: - 行 / 进度

struct InfoRow: View {
    let label: String
    let value: String
    var detail: String?
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()

            Spacer(minLength: 12)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(minHeight: 20)
    }
}

struct MeterBar: View {
    let value: Double
    var total: Double = 100
    var tint: Color = .accentColor
    var height: CGFloat = 6

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(tint.gradient)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.35), value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: - 电量环

struct BatteryRing: View {
    let percent: Int
    let color: Color
    let symbolName: String
    var isCharging = false

    @State private var pulse = false

    private var fraction: CGFloat {
        CGFloat(min(100, max(0, percent))) / 100
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let ringInset = side * 0.14
            let radius = side / 2 - ringInset

            ZStack {
                Circle()
                    .fill(color.opacity(0.055))

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let tickRadius = min(size.width, size.height) / 2 - 3
                    for index in 0..<72 {
                        let angle = (Double(index) * 5.0 - 90.0) * .pi / 180
                        let isActive = Double(index) / 72.0 <= Double(percent) / 100.0
                        let length: CGFloat = index % 6 == 0 ? 7 : 3.5
                        let inner = CGPoint(
                            x: center.x + cos(angle) * Double(tickRadius - length),
                            y: center.y + sin(angle) * Double(tickRadius - length)
                        )
                        let outer = CGPoint(
                            x: center.x + cos(angle) * Double(tickRadius),
                            y: center.y + sin(angle) * Double(tickRadius)
                        )
                        var tick = Path()
                        tick.move(to: inner)
                        tick.addLine(to: outer)
                        context.stroke(
                            tick,
                            with: .color(isActive ? color.opacity(0.7) : Color.primary.opacity(0.085)),
                            lineWidth: index % 6 == 0 ? 1.4 : 0.8
                        )
                    }
                }

                Circle()
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 10)
                    .padding(ringInset)

                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.45), color, color.opacity(0.9)],
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(pulse ? 0.75 : 0.35), radius: pulse ? 16 : 8)
                    .animation(.smooth(duration: 0.55), value: fraction)

                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(fraction) * 360))
                    .shadow(color: color.opacity(0.8), radius: 5)
                    .animation(.smooth(duration: 0.55), value: fraction)

                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(percent)")
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [color.opacity(0.78), color],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Text("%")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { updatePulse() }
        .onChange(of: isCharging) { _, _ in updatePulse() }
        .animation(.smooth(duration: 0.4), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电池电量 \(percent)%")
    }

    private func updatePulse() {
        pulse = false
        guard isCharging else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - 状态胶囊

struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.13)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.16), lineWidth: 1))
            .lineLimit(1)
    }
}

struct HeaderStat: View {
    let label: String
    let value: String
    let systemImage: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 菜单栏

struct BatteryMenuBarLabel: View {
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarBatteryIcon.image(
                percent: monitor.snapshot?.soc ?? 0,
                charging: monitor.snapshot?.charging ?? false,
                available: monitor.snapshot?.batteryPresent ?? false
            ))
            .renderingMode(.template)
            .accessibilityHidden(true)

            Text(monitor.snapshot.map { "\($0.soc)%" } ?? "--")
                .monospacedDigit()
        }
        .accessibilityLabel("MacKit 电池监控")
    }
}

struct BatteryMenuView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let snapshot = monitor.snapshot, snapshot.batteryPresent {
            Text("电量 \(snapshot.soc)% · \(snapshot.stateTitle)")

            if let power = snapshot.powerW {
                Text("电池功率 \(BatteryFormat.watts(power, signed: true))")
            }

            Text("温度 \(BatteryFormat.temperature(snapshot.temperatureC)) · 循环 \(BatteryFormat.number(snapshot.cycleCount)) 次")

            if let watts = snapshot.adapter?.watts {
                Text("适配器 \(watts) W · 系统负载 \(BatteryFormat.watts(snapshot.power?.systemLoadW))")
            }

            if let hardware = monitor.hardware {
                Text("CPU \(BatteryFormat.temperature(hardware.cpuHotspotC)) · GPU \(BatteryFormat.temperature(hardware.gpuHotspotC))")
                Text("风扇 \(Int(hardware.fanRPMTotal.rounded())) RPM · \(hardware.fans.count) 个")
            }
        } else {
            Text(monitor.snapshot == nil ? "正在读取电池信息…" : "未检测到电池")
        }

        Divider()

        Button("打开 MacKit") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("立即刷新") {
            monitor.refreshNow()
        }

        Toggle("自动刷新", isOn: Binding(
            get: { !monitor.isPaused },
            set: { monitor.isPaused = !$0 }
        ))

        Divider()

        Button("退出 MacKit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - 空状态

struct BatteryUnavailableView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "battery.0")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)

            Text("未检测到电池")
                .font(.title2.weight(.semibold))

            Text("这台 Mac 可能使用外接电源、是台式机，或运行在虚拟机中。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("\(snapshot.model) · macOS \(snapshot.osVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

//
//  ThermalDashboardView.swift
//  MacKit
//
//  温度传感器与风扇控制页面。
//

import SwiftUI

struct ThermalDashboardView: View {
    @EnvironmentObject private var monitor: BatteryMonitor

    var body: some View {
        ZStack {
            AuroraBackground(tint: .orange)

            if let hardware = monitor.hardware {
                ScrollView {
                    VStack(spacing: 16) {
                        ThermalHeaderView(hardware: hardware, monitor: monitor)

                        if hardware.smcAvailable {
                            FanControlCard(hardware: hardware, monitor: monitor)

                            HStack(alignment: .top, spacing: 16) {
                                VStack(spacing: 16) {
                                    TemperatureOverviewCard(hardware: hardware)
                                    HottestSensorsCard(hardware: hardware)
                                }
                                .frame(maxWidth: .infinity, alignment: .top)

                                VStack(spacing: 16) {
                                    SensorHeatmapCard(
                                        title: "CPU 核心热区",
                                        subtitle: "\(hardware.cpuSensors.count) 个 P/E 核传感器",
                                        readings: hardware.cpuSensors
                                    )
                                    SensorHeatmapCard(
                                        title: "GPU 热区",
                                        subtitle: "\(hardware.gpuSensors.count) 个 GPU 传感器",
                                        readings: hardware.gpuSensors
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        } else {
                            ContentUnavailableView {
                                Label("SMC 不可用", systemImage: "thermometer.slash")
                            } description: {
                                Text(hardware.note ?? "无法读取温度传感器。")
                            }
                            .frame(maxWidth: .infinity, minHeight: 360)
                        }

                        Text("数据源 AppleSMC · 风扇控制由特权 helper 执行")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 2)
                    }
                    .padding(24)
                    .frame(maxWidth: 1160)
                    .frame(maxWidth: .infinity)
                    .background(ScrollChromeCleaner())
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(nil, for: .top)
                .scrollEdgeEffectHidden(true, for: .top)
                .ignoresSafeArea(.container, edges: .top)
            } else {
                ProgressView("正在读取 SMC 传感器…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - 顶部概览

private struct ThermalHeaderView: View {
    let hardware: HardwareSnapshot
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        HStack(spacing: 24) {
            TemperatureDial(
                title: "CPU 热点",
                value: hardware.cpuHotspotC,
                symbolName: "cpu",
                size: 132
            )

            TemperatureDial(
                title: "GPU 热点",
                value: hardware.gpuHotspotC,
                symbolName: "cpu.fill",
                size: 132
            )

            VStack(alignment: .leading, spacing: 9) {
                Text("散热与温度")
                    .font(.system(size: 25, weight: .bold, design: .rounded))

                HStack(spacing: 7) {
                    Text(monitor.snapshot?.model ?? "Mac")
                    Text("·")
                    Text("\(hardware.fans.count) 风扇")
                    Text("·")
                    Text(monitor.snapshot.map { "macOS \($0.osVersion)" } ?? "macOS")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    StatusPill(text: fanModeTitle, tint: fanModeTint)

                    HStack(spacing: 4) {
                        Image(systemName: "fanblades.fill")
                            .font(.system(size: 9))
                        Text("\(Int(hardware.fanRPMTotal.rounded())) RPM")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 22) {
                    HeaderStat(
                        label: "统一内存",
                        value: BatteryFormat.temperature(hardware.memoryC),
                        systemImage: "memorychip.fill",
                        valueColor: hardware.memoryC.map(temperatureTint) ?? .primary
                    )
                    HeaderStat(
                        label: "NAND",
                        value: BatteryFormat.temperature(hardware.storageC),
                        systemImage: "internaldrive.fill",
                        valueColor: hardware.storageC.map(temperatureTint) ?? .primary
                    )
                    HeaderStat(
                        label: "机身风道",
                        value: BatteryFormat.temperature(hardware.ambientC),
                        systemImage: "wind",
                        valueColor: hardware.ambientC.map(temperatureTint) ?? .primary
                    )
                    HeaderStat(
                        label: "SoC 封装",
                        value: BatteryFormat.temperature(hardware.packageC),
                        systemImage: "square.stack.3d.up.fill",
                        valueColor: hardware.packageC.map(temperatureTint) ?? .primary
                    )
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(monitor.isPaused ? Color.secondary : Color.green)
                        .frame(width: 6, height: 6)
                    Text(monitor.isPaused ? "已暂停" : "实时监控")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let updated = monitor.lastUpdated {
                    Text("更新于 \(updated.formatted(.dateTime.hour().minute().second()))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                MetricSparkline(
                    title: "CPU 趋势",
                    value: hardware.cpuHotspotC.map { String(format: "%.1f °C", $0) } ?? "—",
                    subtitle: nil,
                    values: monitor.history.compactMap(\.cpuTemperatureC).suffix(90).map { $0 },
                    color: .orange
                )
                .frame(width: 150)
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.30))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.18), .red.opacity(0.03), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .orange.opacity(0.22), .white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .orange.opacity(0.10), radius: 20, y: 8)
    }

    private var fanModeTitle: String {
        if monitor.manualFanControl { return "手动风扇控制" }
        if hardware.fans.contains(where: { $0.mode == .system }) { return "系统散热接管" }
        return "系统自动控制"
    }

    private var fanModeTint: Color {
        if monitor.manualFanControl { return .orange }
        if hardware.fans.contains(where: { $0.mode == .system }) { return .purple }
        return .green
    }
}

// MARK: - 风扇控制

private struct FanControlCard: View {
    let hardware: HardwareSnapshot
    @ObservedObject var monitor: BatteryMonitor

    private var connected: Bool { monitor.fanHelperState.isConnected }
    private var manual: Bool { monitor.manualFanControl }

    var body: some View {
        DashboardCard("风扇控制", systemImage: "fanblades.fill", tint: .orange) {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    helperStatus

                    Spacer(minLength: 8)

                    if !connected {
                        Button {
                            monitor.enableFanControl()
                        } label: {
                            HStack(spacing: 5) {
                                if monitor.fanBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "lock.open.fill")
                                }
                                Text(monitor.fanBusy ? "等待授权…" : "启用风扇控制")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .disabled(monitor.fanBusy)
                    } else {
                        Toggle("手动控制", isOn: Binding(
                            get: { manual },
                            set: { monitor.setManualMode($0) }
                        ))
                        .toggleStyle(.switch)
                        .tint(.orange)
                        .controlSize(.small)
                        .disabled(monitor.fanBusy)

                        Button {
                            monitor.restoreAutoFans()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("全部恢复系统自动控制")
                    }
                }

                if let error = monitor.fanError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            monitor.clearFanError()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.orange.opacity(0.10))
                    )
                }

                if connected && manual {
                    HStack(spacing: 8) {
                        ForEach(BatteryMonitor.FanPreset.allCases) { preset in
                            Button {
                                monitor.applyPreset(preset)
                            } label: {
                                Label(preset.title, systemImage: preset.symbolName)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(preset == .maximum ? .red : .orange)
                        }

                        Spacer()

                        Text("手动模式会持续保持，直到恢复自动或退出 App")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(spacing: 12) {
                    ForEach(hardware.fans) { fan in
                        FanRow(fan: fan, connected: connected, manual: manual, monitor: monitor)
                    }
                }

                if !connected {
                    HStack(spacing: 7) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.orange)
                        Text("首次启用需要管理员密码，用于安装 \(FanHelperInstaller.installedHelperPath)。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(.red.opacity(0.8))
                    Text("手动控制会绕过 macOS 的自动散热策略。温度超过 100°C、helper 心跳超时或退出 App 时，会自动恢复系统控制。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var helperStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(helperColor)
                .frame(width: 6, height: 6)
            Text(monitor.fanHelperState.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if monitor.fanHelperState == .starting {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(helperColor.opacity(0.10)))
    }

    private var helperColor: Color {
        switch monitor.fanHelperState {
        case .connected: .green
        case .starting: .orange
        case .failed: .red
        case .inactive: .secondary
        }
    }
}

private struct FanRow: View {
    let fan: FanInfo
    let connected: Bool
    let manual: Bool
    @ObservedObject var monitor: BatteryMonitor

    private var target: Double { monitor.target(for: fan) }

    private var targetDescription: String {
        let actual = Int((fan.actualRPM ?? 0).rounded())
        if manual {
            return "当前 \(actual) RPM · 目标 \(Int(target.rounded())) RPM"
        }
        if let systemTarget = fan.targetRPM, systemTarget > 0 {
            return "当前 \(actual) RPM · 系统目标 \(Int(systemTarget.rounded())) RPM"
        }
        return actual > 0 ? "系统自动 · 当前 \(actual) RPM" : "系统自动 · 风扇待机"
    }

    private var modeColor: Color {
        switch fan.mode {
        case .manual: .orange
        case .auto, .system: .teal
        case .unknown: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            FanTachometer(fan: fan, size: 76)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(fan.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(fan.mode.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(modeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(modeColor.opacity(0.10)))
                }

                Text(targetDescription)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("\(Int(fan.safeMinimum.rounded())) – \(Int(fan.safeMaximum.rounded())) RPM")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if connected && manual {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { target },
                            set: { monitor.setFanTarget(index: fan.index, rpm: $0) }
                        ),
                        in: fan.safeMinimum...fan.safeMaximum,
                        step: 50,
                        onEditingChanged: { editing in
                            if !editing {
                                monitor.applyFanTarget(index: fan.index)
                            }
                        }
                    )
                    .tint(modeColor)
                    .frame(width: 210)

                    HStack {
                        Text("\(Int(fan.safeMinimum.rounded()))")
                        Spacer()
                        Text("\(Int(fan.safeMaximum.rounded()))")
                    }
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 210)
                }
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    Label(
                        connected ? "系统自动管理" : "启用后可手动调速",
                        systemImage: connected ? "wand.and.stars" : "lock.fill"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                    Text("\(Int(fan.safeMinimum.rounded())) – \(Int(fan.safeMaximum.rounded())) RPM")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 210, alignment: .trailing)
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        }
    }
}

// MARK: - 温度概览

private struct TemperatureOverviewCard: View {
    let hardware: HardwareSnapshot

    private var items: [TemperatureItem] {
        [
            .init(
                title: "CPU 热点",
                subtitle: hardware.cpuAverageC.map { String(format: "核心平均 %.1f°C", $0) } ?? "P / E 核",
                value: hardware.cpuHotspotC,
                key: "TCMz",
                group: .cpu
            ),
            .init(
                title: "GPU 热点",
                subtitle: hardware.gpuAverageC.map { String(format: "核心平均 %.1f°C", $0) } ?? "GPU 核心",
                value: hardware.gpuHotspotC,
                key: "TRDX",
                group: .gpu
            ),
            .init(title: "统一内存", subtitle: "LPDDR5", value: hardware.memoryC, key: "TVm0", group: .memory),
            .init(title: "NAND", subtitle: "闪存", value: hardware.storageC, key: "TH0x", group: .storage),
            .init(title: "电池", subtitle: "电池包", value: hardware.batteryC, key: "TB0T", group: .battery),
            .init(title: "Wi-Fi", subtitle: "无线模块", value: hardware.wifiC, key: "TW0P", group: .system),
            .init(title: "VRM", subtitle: "供电相", value: hardware.vrmC, key: "TVD0", group: .power),
            .init(title: "机身", subtitle: "风道", value: hardware.ambientC, key: "TAOL", group: .system)
        ]
    }

    var body: some View {
        DashboardCard("温度概览", systemImage: "thermometer.medium", tint: .green) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)],
                spacing: 9
            ) {
                ForEach(items) { item in
                    TemperatureTile(item: item)
                }
            }
        }
    }

    private struct TemperatureItem: Identifiable {
        let title: String
        let subtitle: String
        let value: Double?
        let key: String
        let group: TemperatureGroup

        var id: String { key }
    }

    private struct TemperatureTile: View {
        let item: TemperatureItem

        var body: some View {
            let color = item.value.map(temperatureTint) ?? .secondary

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: groupSymbol)
                        .font(.system(size: 9, weight: .medium))
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(item.value.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Text("°C")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                MeterBar(
                    value: item.value ?? 0,
                    total: 110,
                    tint: color,
                    height: 3
                )

                Text(item.subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.065))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color.opacity(0.14), lineWidth: 1)
            }
        }

        private var groupSymbol: String {
            switch item.group {
            case .cpu: "cpu"
            case .gpu: "cpu.fill"
            case .memory: "memorychip.fill"
            case .storage: "internaldrive.fill"
            case .battery: "battery.100"
            case .system: "wind"
            case .display: "display"
            case .power: "bolt.fill"
            case .other: "thermometer.medium"
            }
        }
    }
}

// MARK: - 热区与排行

private struct SensorHeatmapCard: View {
    let title: String
    let subtitle: String
    let readings: [TemperatureReading]

    var body: some View {
        DashboardCard(title, systemImage: "square.grid.3x3.fill", tint: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if readings.isEmpty {
                    Text("暂无传感器数据")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    HeatmapView(readings: readings, columns: 6)
                }

                HeatmapLegend()
            }
        }
    }
}

private struct HottestSensorsCard: View {
    let hardware: HardwareSnapshot

    var body: some View {
        DashboardCard("全机热点", systemImage: "flame.fill", tint: .red) {
            VStack(spacing: 7) {
                if hardware.hottest.isEmpty {
                    Text("暂无传感器数据")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hardware.hottest.prefix(8)) { sensor in
                        let color = temperatureTint(sensor.celsius)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color)
                                .frame(width: 5, height: 5)

                            Text(sensor.name)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(sensor.key)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)

                            Spacer(minLength: 6)

                            Text(sensor.formatted)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(color)
                        }
                    }
                }
            }
        }
    }
}

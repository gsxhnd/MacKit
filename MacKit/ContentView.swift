//
//  ContentView.swift
//  MacKit
//
//  电池与电源实时仪表盘。
//

import SwiftUI

struct BatteryDashboardView: View {
    @EnvironmentObject private var monitor: BatteryMonitor

    var body: some View {
        ZStack {
            AuroraBackground(tint: monitor.snapshot?.state.tint ?? .accentColor)

            if let snapshot = monitor.snapshot {
                ScrollView {
                    VStack(spacing: 16) {
                        BatteryHeaderView(snapshot: snapshot, monitor: monitor)

                        if snapshot.batteryPresent {
                            if let warning = snapshot.warning {
                                warningBanner(warning)
                            }

                            BatteryTrendCard(snapshot: snapshot, history: monitor.history)
                            cards(for: snapshot)
                            BatteryInfoCard(snapshot: snapshot)
                        } else {
                            BatteryUnavailableView(snapshot: snapshot)
                        }

                        footer
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
                ProgressView("正在读取电池信息…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 卡片

    private func cards(for snapshot: BatterySnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                statusCard(snapshot)
                electricalCard(snapshot)

                if snapshot.adapter != nil {
                    chargerCard(snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            VStack(spacing: 16) {
                capacityCard(snapshot)
                temperatureCard(snapshot)

                if snapshot.power != nil {
                    telemetryCard(snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func statusCard(_ snapshot: BatterySnapshot) -> some View {
        DashboardCard("状态", systemImage: "bolt.fill", tint: snapshot.state.tint) {
            VStack(spacing: 9) {
                InfoRow(label: "电源来源", value: snapshot.sourceTitle)
                InfoRow(label: "充放电状态", value: snapshot.stateTitle, valueColor: snapshot.state.tint)
                InfoRow(label: "时间估计", value: snapshot.etaText)
                InfoRow(
                    label: "电量 SoC",
                    value: "\(snapshot.soc)%",
                    detail: snapshot.rawSOC.map { "电量计 \($0)%" }
                )
            }
        }
    }

    private func electricalCard(_ snapshot: BatterySnapshot) -> some View {
        DashboardCard("电气参数", systemImage: "waveform.path.ecg", tint: .blue) {
            VStack(spacing: 9) {
                InfoRow(
                    label: "电池总电压",
                    value: BatteryFormat.volts(snapshot.voltageV)
                )
                InfoRow(
                    label: "电流",
                    value: currentText(snapshot),
                    valueColor: currentColor(snapshot)
                )
                InfoRow(
                    label: "电池功率",
                    value: powerText(snapshot),
                    valueColor: powerColor(snapshot)
                )

                if !snapshot.cellVoltagesMV.isEmpty {
                    Divider().opacity(0.5).padding(.vertical, 2)
                    CellVoltageList(cells: snapshot.cellVoltagesMV)
                }

                if let charger = snapshot.charger,
                   let current = charger.chargingCurrentMA, current > 0 {
                    Divider().opacity(0.5).padding(.vertical, 2)
                    InfoRow(
                        label: "充电设定",
                        value: "\(current.formatted(.number.grouping(.automatic))) mA",
                        detail: charger.chargingVoltageV.map {
                            String(format: "%.3f V/芯", $0)
                        }
                    )
                }
            }
        }
    }

    private func capacityCard(_ snapshot: BatterySnapshot) -> some View {
        let health = snapshot.healthPercent
        let healthColor = self.healthColor(health)
        let cycleColor = self.cycleColor(snapshot)

        return DashboardCard("容量与健康", systemImage: "heart.fill", tint: healthColor) {
            VStack(spacing: 9) {
                if let health {
                    HStack(alignment: .firstTextBaseline) {
                        Text("容量保持率")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .help("按满充容量 ÷ 设计容量计算；macOS 系统设置可能采用不同的校准基准")
                        Spacer()
                        Text("\(health)%")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(healthColor)
                    }
                    MeterBar(value: Double(health), tint: healthColor, height: 7)
                        .padding(.bottom, 2)
                }

                InfoRow(
                    label: "当前电量",
                    value: BatteryFormat.capacity(snapshot.currentCapacityMAh)
                )
                InfoRow(
                    label: "满充容量",
                    value: BatteryFormat.capacity(snapshot.fullChargeCapacityMAh),
                    detail: snapshot.designCapacityMAh.map {
                        "设计 \($0.formatted(.number.grouping(.automatic))) mAh"
                    }
                )
                if let nominal = snapshot.nominalCapacityMAh {
                    InfoRow(label: "标称容量", value: BatteryFormat.capacity(nominal))
                }
                if let condition = snapshot.healthConditionText {
                    InfoRow(label: "系统健康", value: condition, valueColor: healthColor)
                }

                Divider().opacity(0.5).padding(.vertical, 2)

                HStack(alignment: .firstTextBaseline) {
                    Text("循环次数")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(cycleText(snapshot))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(cycleColor)
                }
                MeterBar(
                    value: Double(snapshot.cycleCount ?? 0),
                    total: Double(max(1, snapshot.designCycleCount)),
                    tint: cycleColor,
                    height: 5
                )

                if let remaining = snapshot.cycleRemaining {
                    Text("设计寿命剩余 \(remaining.formatted(.number.grouping(.automatic))) 次")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if !snapshot.qmaxMAh.isEmpty {
                    InfoRow(
                        label: "电芯 Qmax",
                        value: snapshot.qmaxMAh.map { "\($0)" }.joined(separator: " / "),
                        detail: "mAh"
                    )
                }
            }
        }
    }

    private func temperatureCard(_ snapshot: BatterySnapshot) -> some View {
        DashboardCard("温度", systemImage: "thermometer.medium", tint: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(BatteryFormat.temperature(snapshot.temperatureC))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    Spacer()

                    if let temperature = snapshot.temperatureC {
                        Text(temperatureLabel(temperature))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(temperatureColor(temperature))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(temperatureColor(temperature).opacity(0.12))
                            )
                    }
                }

                if let lifetime = snapshot.lifetime {
                    Divider().opacity(0.5)
                    InfoRow(
                        label: "历史平均",
                        value: BatteryFormat.temperature(lifetime.averageTemperatureC)
                    )
                    InfoRow(label: "历史区间", value: temperatureRange(lifetime))
                }
            }
        }
    }

    private func chargerCard(_ snapshot: BatterySnapshot) -> some View {
        let adapter = snapshot.adapter
        return DashboardCard("充电器", systemImage: "powerplug.fill", tint: .purple) {
            VStack(spacing: 9) {
                if let watts = adapter?.watts {
                    HStack(alignment: .firstTextBaseline) {
                        Text("额定功率")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(watts) W")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }

                if let voltage = adapter?.voltageV, let current = adapter?.currentA {
                    InfoRow(
                        label: "输出规格",
                        value: String(format: "%.1f V / %.2f A", voltage, current)
                    )
                }

                InfoRow(
                    label: "类型",
                    value: adapterTypeName(adapter),
                    detail: adapter?.isWireless == true ? "无线" : "有线"
                )

                if let load = snapshot.adapterLoadPercent {
                    Divider().opacity(0.5).padding(.vertical, 2)
                    HStack(alignment: .firstTextBaseline) {
                        Text("负载率")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(load)%")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                    }
                    MeterBar(value: Double(load), tint: .purple, height: 5)
                }
            }
        }
    }

    private func telemetryCard(_ snapshot: BatterySnapshot) -> some View {
        let telemetry = snapshot.power
        return DashboardCard("整机功耗", systemImage: "chart.bar.fill", tint: .teal) {
            VStack(spacing: 9) {
                if let load = telemetry?.systemLoadW {
                    HStack(alignment: .firstTextBaseline) {
                        Text("系统负载")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(BatteryFormat.watts(load))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }

                InfoRow(
                    label: "电池贡献",
                    value: BatteryFormat.watts(snapshot.powerW.map(abs)),
                    detail: powerDirection(snapshot)
                )
                InfoRow(
                    label: "适配器输入",
                    value: BatteryFormat.watts(telemetry?.systemPowerInW),
                    detail: telemetry?.adapterLossW.map { "损耗 \(BatteryFormat.watts($0))" }
                )
                if let voltage = telemetry?.systemVoltageInV, voltage > 0 {
                    InfoRow(label: "输入电压", value: BatteryFormat.volts(voltage))
                }
            }
        }
    }

    // MARK: - 提示 / 页脚

    private func warningBanner(_ text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("数据源 IOKit · AppleSmartBattery · IOPS", systemImage: "internaldrive")
            Spacer()
            Text(monitor.isPaused ? "自动刷新已暂停" : "每 \(monitor.refreshRate.rawValue) 秒自动刷新")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: - 格式化

    private func currentText(_ snapshot: BatterySnapshot) -> String {
        guard let current = snapshot.amperageMA else { return "—" }
        let value = current.formatted(.number.grouping(.automatic))
        return current > 0 ? "+\(value) mA" : "\(value) mA"
    }

    private func currentColor(_ snapshot: BatterySnapshot) -> Color {
        guard let current = snapshot.amperageMA else { return .primary }
        if current > 0 { return .green }
        if current < 0 { return .orange }
        return .secondary
    }

    private func powerText(_ snapshot: BatterySnapshot) -> String {
        guard let power = snapshot.powerW else { return "—" }
        if power > 0.005 {
            return "\(BatteryFormat.watts(power, signed: true)) 充入"
        }
        if power < -0.005 {
            return "\(BatteryFormat.watts(power)) 输出"
        }
        return "0.00 W 静置"
    }

    private func powerColor(_ snapshot: BatterySnapshot) -> Color {
        guard let power = snapshot.powerW else { return .primary }
        if power > 0.005 { return .green }
        if power < -0.005 { return .orange }
        return .secondary
    }

    private func adapterTypeName(_ adapter: AdapterInfo?) -> String {
        guard let name = adapter?.name?.trimmed, !name.isEmpty else { return "PD" }
        if name.lowercased() == "pd charger" { return "PD charger" }
        return name
    }

    private func powerDirection(_ snapshot: BatterySnapshot) -> String? {
        guard let power = snapshot.powerW else { return nil }
        if power > 0.005 { return "充入" }
        if power < -0.005 { return "输出" }
        return "静置"
    }

    private func cycleText(_ snapshot: BatterySnapshot) -> String {
        guard let cycles = snapshot.cycleCount else { return "—" }
        return "\(cycles.formatted(.number.grouping(.automatic))) / \(snapshot.designCycleCount.formatted(.number.grouping(.automatic))) 次"
    }

    private func healthColor(_ health: Int?) -> Color {
        guard let health else { return .green }
        if health >= 90 { return .green }
        if health >= 80 { return .orange }
        return .red
    }

    private func cycleColor(_ snapshot: BatterySnapshot) -> Color {
        guard let cycles = snapshot.cycleCount, snapshot.designCycleCount > 0 else { return .green }
        let ratio = Double(cycles) / Double(snapshot.designCycleCount)
        if ratio >= 0.8 { return .red }
        if ratio >= 0.6 { return .orange }
        return .green
    }

    private func temperatureLabel(_ value: Double) -> String {
        switch value {
        case ..<10: "偏冷"
        case 10..<35: "正常"
        case 35..<45: "偏热"
        default: "过热"
        }
    }

    private func temperatureColor(_ value: Double) -> Color {
        switch value {
        case ..<10: .blue
        case 10..<35: .green
        case 35..<45: .orange
        default: .red
        }
    }

    private func temperatureRange(_ lifetime: BatteryLifetime) -> String {
        let minimum = lifetime.minTemperatureC.map { String(format: "%.0f", $0) } ?? "—"
        let maximum = lifetime.maxTemperatureC.map { String(format: "%.0f", $0) } ?? "—"
        return "\(minimum)–\(maximum) °C"
    }
}

// MARK: - 顶部概览

private struct BatteryHeaderView: View {
    let snapshot: BatterySnapshot
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 24) {
                BatteryRing(
                    percent: snapshot.soc,
                    color: snapshot.state.tint,
                    symbolName: snapshot.state.symbolName,
                    isCharging: snapshot.charging
                )
                .frame(width: 148, height: 148)
                .padding(.leading, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("电池 · 电源全景")
                        .font(.system(size: 23, weight: .bold, design: .rounded))

                    HStack(spacing: 7) {
                        Text(snapshot.model)
                        Text("·")
                        Text("macOS \(snapshot.osVersion)")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        StatusPill(text: snapshot.stateTitle, tint: snapshot.state.tint)

                        if let condition = snapshot.healthConditionText {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 9))
                                Text(condition)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 7) {
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

                    Text("每 \(monitor.refreshRate.rawValue) 秒刷新")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider().opacity(0.55)

            HStack(spacing: 18) {
                HeaderStat(
                    label: "电源来源",
                    value: snapshot.sourceTitle,
                    systemImage: "powerplug.fill"
                )
                HeaderStat(
                    label: "时间估计",
                    value: snapshot.etaText,
                    systemImage: "clock.fill"
                )
                HeaderStat(
                    label: "电池温度",
                    value: BatteryFormat.temperature(snapshot.temperatureC),
                    systemImage: "thermometer.medium",
                    valueColor: snapshot.temperatureC.map { $0 >= 35 ? .orange : .primary } ?? .primary
                )
                HeaderStat(
                    label: "系统负载",
                    value: BatteryFormat.watts(snapshot.power?.systemLoadW),
                    systemImage: "chart.bar.fill"
                )
                HeaderStat(
                    label: "CPU 温度",
                    value: monitor.hardware?.cpuHotspotC.map { String(format: "%.1f °C", $0) } ?? "—",
                    systemImage: "cpu",
                    valueColor: monitor.hardware?.cpuHotspotC.map { temperatureTint($0) } ?? .primary
                )
            }

            Divider().opacity(0.45)

            EnergyFlowView(snapshot: snapshot)
                .frame(maxWidth: .infinity)
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.28))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    snapshot.state.tint.opacity(0.20),
                                    snapshot.state.tint.opacity(0.03),
                                    Color.blue.opacity(0.06)
                                ],
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
                        colors: [
                            .white.opacity(0.35),
                            snapshot.state.tint.opacity(0.25),
                            .white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: snapshot.state.tint.opacity(0.12), radius: 22, y: 8)
    }
}

// MARK: - 实时趋势

private struct BatteryTrendCard: View {
    let snapshot: BatterySnapshot
    let history: [BatteryMonitor.HistorySample]

    private var samples: [BatteryMonitor.HistorySample] {
        Array(history.suffix(90))
    }

    var body: some View {
        DashboardCard("实时趋势", systemImage: "waveform.path.ecg.rectangle", tint: snapshot.state.tint) {
            HStack(alignment: .top, spacing: 22) {
                MetricSparkline(
                    title: "电池功率",
                    value: BatteryFormat.watts(snapshot.powerW, signed: true),
                    subtitle: "最近 \(samples.count) 次采样",
                    values: samples.compactMap(\.powerW),
                    color: snapshot.state.tint
                )
                .frame(maxWidth: .infinity)

                Divider().opacity(0.45).frame(height: 64)

                MetricSparkline(
                    title: "电池温度",
                    value: BatteryFormat.temperature(snapshot.temperatureC),
                    subtitle: "当前电池包温度",
                    values: samples.compactMap(\.batteryTemperatureC),
                    color: .orange
                )
                .frame(maxWidth: .infinity)

                Divider().opacity(0.45).frame(height: 64)

                MetricSparkline(
                    title: "CPU 热点",
                    value: monitorCPUText,
                    subtitle: "来自 SMC 温度传感器",
                    values: samples.compactMap(\.cpuTemperatureC),
                    color: .red
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var monitorCPUText: String {
        guard let value = samples.compactMap(\.cpuTemperatureC).last else { return "—" }
        return String(format: "%.1f °C", value)
    }
}

// MARK: - 电芯电压

private struct CellVoltageList: View {
    let cells: [Int]

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text("电芯电压")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(cells.count) 串")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(cells.enumerated()), id: \.offset) { index, millivolts in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10, alignment: .trailing)

                    MeterBar(
                        value: Double(millivolts - 3000),
                        total: 1500,
                        tint: .blue,
                        height: 4
                    )

                    Text("\(millivolts) mV")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - 电池信息

private struct BatteryInfoCard: View {
    let snapshot: BatterySnapshot

    private var manufactureDate: String {
        guard let date = snapshot.manufactureDate else { return "—" }
        return date.formatted(date: .numeric, time: .omitted)
    }

    var body: some View {
        DashboardCard("电池信息", systemImage: "info.circle.fill", tint: .gray) {
            HStack(alignment: .top, spacing: 32) {
                VStack(spacing: 9) {
                    InfoRow(label: "电量计芯片", value: snapshot.deviceName ?? "—")
                    InfoRow(label: "序列号", value: snapshot.hardwareSerial ?? "—")
                    InfoRow(
                        label: "低电量模式",
                        value: snapshot.lowPowerMode ? "开启" : "关闭",
                        valueColor: snapshot.lowPowerMode ? .orange : .primary
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 9) {
                    InfoRow(
                        label: "GasGauge 固件",
                        value: snapshot.firmwareVersion ?? "—"
                    )
                    InfoRow(label: "生产日期", value: manufactureDate)
                    InfoRow(label: "电池状态", value: snapshot.healthConditionText ?? "—")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

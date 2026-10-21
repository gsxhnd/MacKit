//
//  TrayPanelView.swift
//  MacKit
//
//  菜单栏左键弹出的状态面板。
//  信息结构对齐 status-trio 的 popover：
//    电池 → 温度与风扇 → 网络 → 音量 → 蓝牙 → 底部操作。
//

import AppKit
import SwiftUI

struct TrayPanelView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var volume: VolumeMonitor
    @EnvironmentObject private var bluetooth: BluetoothMonitor
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let snapshot = monitor.snapshot, snapshot.batteryPresent {
                batterySection(snapshot)
            } else {
                Text(monitor.snapshot == nil ? "正在读取电池信息…" : "未检测到电池")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
            thermalSection

            Divider()
            networkSection

            Divider()
            volumeSection

            if !bluetooth.pairedDevices.isEmpty {
                Divider()
                bluetoothSection
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 14) {
            BatteryRing(
                percent: monitor.snapshot?.soc ?? 0,
                color: powerState.tint,
                symbolName: powerState.symbolName,
                isCharging: monitor.snapshot?.charging ?? false
            )
            .frame(width: 60, height: 60)
            .opacity(monitor.snapshot?.batteryPresent == true ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(percentText)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    if monitor.snapshot?.batteryPresent == true {
                        StatusPill(text: powerState.panelTitle, tint: powerState.tint)
                    }
                }

                Text(detailLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 电池

    private func batterySection(_ snapshot: BatterySnapshot) -> some View {
        VStack(spacing: 5) {
            InfoRow(
                label: "电池功率",
                value: BatteryFormat.watts(snapshot.powerW, signed: true)
            )
            InfoRow(
                label: "电池温度",
                value: BatteryFormat.temperature(snapshot.temperatureC)
            )
            InfoRow(
                label: "循环次数",
                value: snapshot.cycleCount.map { "\($0) 次" } ?? "—",
                detail: snapshot.healthPercent.map { "健康度 \($0)%" }
            )
            InfoRow(
                label: "充电上限",
                value: chargeLimitText(snapshot.chargeLimit)
            )
            if let adapter = snapshot.adapter {
                InfoRow(
                    label: "适配器",
                    value: adapter.watts.map { "\($0) W" } ?? "—",
                    detail: snapshot.sourceTitle
                )
            }
        }
    }

    // MARK: - 温度与风扇

    private var thermalSection: some View {
        VStack(spacing: 5) {
            InfoRow(
                label: "CPU 热点",
                value: BatteryFormat.temperature(monitor.hardware?.cpuHotspotC),
                valueColor: temperatureColor(monitor.hardware?.cpuHotspotC)
            )
            InfoRow(
                label: "GPU 热点",
                value: BatteryFormat.temperature(monitor.hardware?.gpuHotspotC),
                valueColor: temperatureColor(monitor.hardware?.gpuHotspotC)
            )
            InfoRow(
                label: "风扇",
                value: fanSummary,
                detail: monitor.hardware.map { "\($0.fans.count) 个" }
            )
        }
    }

    // MARK: - 网络

    private var networkSection: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: networkSymbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)

                Text(networkTitle)
                    .font(.system(size: 11, weight: .medium))

                Spacer(minLength: 8)

                if let ssid = network.snapshot.ssid, network.snapshot.isWiFiAssociated {
                    Text(ssid)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            }

            if network.snapshot.isWiFiAssociated {
                InfoRow(label: "信号", value: network.snapshot.signalText)
            } else if network.snapshot.connection == .ethernet {
                InfoRow(label: "连接", value: "以太网")
            }
        }
    }

    // MARK: - 音量

    private var volumeSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    volume.toggleMute()
                } label: {
                    Image(systemName: volumeMuteSymbol)
                        .font(.system(size: 12))
                        .frame(width: 15)
                }
                .buttonStyle(.borderless)
                .help(volume.snapshot.isMuted ? "取消静音" : "静音")

                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.small)
                    .disabled(!volume.snapshot.canSetVolume)

                Text(volumePercentText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("输出设备")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)

                if volume.outputDevices.isEmpty {
                    Text("未发现输出设备")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(volume.outputDevices.prefix(3)) { device in
                        outputDeviceRow(device)
                    }
                }
            }
        }
    }

    // MARK: - 蓝牙

    private var bluetoothSection: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Label("蓝牙", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                if bluetooth.pendingAddress != nil {
                    Text("处理中…")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(bluetooth.pairedDevices.prefix(3)) { device in
                HStack(spacing: 6) {
                    Image(systemName: device.kind.symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(device.name)
                        .font(.system(size: 11, weight: device.isConnected ? .medium : .regular))
                        .foregroundStyle(device.isConnected ? .primary : .secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let battery = device.batterySummary {
                        Text(battery)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Button(device.isConnected ? "断开" : "连接") {
                        toggleBluetooth(device)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .disabled(bluetooth.pendingAddress != nil)
                }
            }
        }
    }

    /// 托盘内直接连接 / 断开蓝牙设备；连接后自动把它切换为输出设备。
    private func toggleBluetooth(_ device: BluetoothDeviceInfo) {
        let connecting = !device.isConnected
        bluetooth.setConnected(device, connected: connecting)
        guard connecting else { return }

        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            volume.refreshDevices()
            try? await Task.sleep(nanoseconds: 700_000_000)
            volume.selectDevice(matchingName: device.name)
        }
    }

    // MARK: - 底部操作

    /// 底部结构对齐 status-trio 的 PopoverFooterView：
    /// 主操作按钮 + 版本号 + 「更多」菜单。
    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onOpenMainWindow) {
                Label("打开 MacKit", systemImage: "macwindow")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer(minLength: 0)

            Text(appVersion)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize()

            Menu {
                Button("立即刷新") {
                    refreshAll()
                }

                Button(monitor.isPaused ? "继续自动刷新" : "暂停自动刷新") {
                    monitor.isPaused.toggle()
                }

                Divider()

                Button("退出 MacKit") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 绑定与派生

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { volume.snapshot.scalar ?? 0 },
            set: { volume.setVolume($0) }
        )
    }

    private func refreshAll() {
        monitor.refreshNow()
        network.refreshNow()
        volume.refresh()
        bluetooth.refreshNow()
    }

    private var powerState: BatteryPowerState {
        monitor.snapshot?.state ?? .unavailable
    }

    private var percentText: String {
        monitor.snapshot.map { "\($0.soc)%" } ?? "--"
    }

    private var detailLine: String {
        guard let snapshot = monitor.snapshot, snapshot.batteryPresent else {
            return monitor.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "等待数据"
        }
        return snapshot.etaText
    }

    private func chargeLimitText(_ limit: Int?) -> String {
        guard let limit, limit < 100 else { return "未设置" }
        return "\(limit)%"
    }

    private var fanSummary: String {
        guard let hardware = monitor.hardware, hardware.smcAvailable, !hardware.fans.isEmpty else {
            return "—"
        }
        return "\(Int(hardware.fanRPMTotal.rounded())) RPM"
    }

    private var volumePercentText: String {
        guard let scalar = volume.snapshot.scalar else { return "—" }
        return "\(Int((scalar * 100).rounded()))%"
    }

    /// 输出设备行，交互对齐 status-trio 的 OutputDeviceRow：
    /// 点整行即切换系统默认输出，当前设备高亮 + 勾选。
    private func outputDeviceRow(_ device: AudioOutputDeviceInfo) -> some View {
        Button {
            volume.selectDevice(device.id)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(device.isCurrent ? Color.accentColor : Color.secondary.opacity(0.14))
                    Image(systemName: device.kind.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(device.isCurrent ? Color.white : Color.secondary)
                }
                .frame(width: 20, height: 20)

                Text(device.name)
                    .font(.system(size: 11, weight: device.isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(device.kind.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                if device.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(device.kind.title)
    }

    private var volumeMuteSymbol: String {
        if volume.snapshot.isMuted { return "speaker.slash.fill" }
        guard let scalar = volume.snapshot.scalar else { return "speaker.wave.2" }
        switch scalar {
        case 0: return "speaker"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var networkTitle: String {
        if network.snapshot.connection == .ethernet {
            return "以太网"
        }
        switch network.snapshot.wifi {
        case .connected: return "Wi-Fi 已连接"
        case .noInternet: return "Wi-Fi 无互联网"
        case .notAssociated: return "Wi-Fi 未连接"
        case .off: return "Wi-Fi 已关闭"
        case .unavailable: return "无 Wi-Fi"
        }
    }

    private var networkSymbolName: String {
        if network.snapshot.connection == .ethernet {
            return "cable.connector"
        }
        switch network.snapshot.wifi {
        case .connected: return "wifi"
        case .noInternet: return "wifi.exclamationmark"
        case .notAssociated: return "wifi"
        case .off, .unavailable: return "wifi.slash"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func temperatureColor(_ celsius: Double?) -> Color {
        guard let celsius else { return .primary }
        if celsius >= TraySceneMapper.criticalTemperatureC { return .red }
        if celsius >= TraySceneMapper.warmTemperatureC { return .orange }
        return .primary
    }
}

// MARK: - 状态文案

private extension BatteryPowerState {
    var panelTitle: String {
        switch self {
        case .unavailable: "不可用"
        case .critical: "电量极低"
        case .charging: "充电中"
        case .charged: "已充满"
        case .pluggedNotCharging: "插电未充电"
        case .discharging: "放电中"
        }
    }
}

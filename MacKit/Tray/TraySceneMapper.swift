//
//  TraySceneMapper.swift
//  MacKit
//
//  把电池 / 网络 / 音量状态映射为托盘图标场景。
//  结构与 status-trio 的三信号一致：
//    - 顶部圆环 = 电池（进度 + 状态色 + 顶部指示器）
//    - 中心符号 = 网络（Wi-Fi 信号格 / 以太网；蓝牙音频可替换）
//    - 底部     = 音量（圆点或弧线；蓝牙音频可转蓝）
//
//  与 status-trio 一致：常态只用菜单栏前景色，仅电池状态与蓝牙音频着色。
//

import Foundation

/// 底部音量的绘制样式，对齐 status-trio 的 VolumeDisplayStyle。
nonisolated enum TrayVolumeStyle: String, Equatable, Sendable {
    case dots
    case arc
}

/// 托盘图标偏好，与 status-trio 的 BatteryIconOptions / VolumeIconOptions 对应。
nonisolated struct TrayIconOptions: Equatable, Sendable {
    var showsPercentage: Bool
    var showsPercentageWhenConnected: Bool
    var usesStatusColors: Bool
    var volumeStyle: TrayVolumeStyle
    /// 蓝牙音频播放时，用设备符号替换网络图标。
    var replacesNetworkIconWithBluetoothAudio: Bool
    /// 蓝牙音频播放时，音量圆点 / 弧线转为蓝色。
    var usesBluetoothVolumeColor: Bool

    init(
        showsPercentage: Bool = true,
        showsPercentageWhenConnected: Bool = false,
        usesStatusColors: Bool = true,
        volumeStyle: TrayVolumeStyle = .dots,
        replacesNetworkIconWithBluetoothAudio: Bool = false,
        usesBluetoothVolumeColor: Bool = false
    ) {
        self.showsPercentage = showsPercentage
        self.showsPercentageWhenConnected = showsPercentageWhenConnected
        self.usesStatusColors = usesStatusColors
        self.volumeStyle = volumeStyle
        self.replacesNetworkIconWithBluetoothAudio = replacesNetworkIconWithBluetoothAudio
        self.usesBluetoothVolumeColor = usesBluetoothVolumeColor
    }

    static let standard = TrayIconOptions()
}

enum TraySceneMapper {
    /// 电量低于该值时圆环转红。
    static let criticalThreshold = 20
    /// 热点温度偏高阈值（面板文字使用）。
    static let warmTemperatureC = 80.0
    /// 热点温度过高阈值（面板文字使用）。
    static let criticalTemperatureC = 95.0

    static func scene(
        battery: BatterySnapshot?,
        network: NetworkSnapshot?,
        volume: VolumeSnapshot?,
        options: TrayIconOptions = .standard
    ) -> TrayIconScene {
        TrayIconScene(
            outerRing: batteryRing(battery, options: options),
            center: centerState(network: network, volume: volume, options: options),
            footer: volumeFooter(volume, options: options)
        )
    }

    // MARK: - 顶部圆环（电池）

    private static func batteryRing(_ battery: BatterySnapshot?, options: TrayIconOptions) -> TrayOuterRing {
        guard let battery, battery.batteryPresent else {
            // 无电池：空环，中心交给网络符号表达。
            return TrayOuterRing(segments: [TrayRingSegment(progress: 0, color: .primary)])
        }

        let role: TrayIconColorRole
        if options.usesStatusColors {
            if battery.critical || battery.soc < criticalThreshold {
                role = .critical
            } else if battery.lowPowerMode {
                role = .lowPower
            } else if battery.charging || battery.externalConnected {
                role = .powered
            } else {
                role = .primary
            }
        } else {
            role = .primary
        }

        // 与 status-trio 的 batteryGapContent 一致：
        // 充电显示闪电；插电未充电显示插头（除非用户要求插电时显示百分比）；
        // 其余情况显示电量百分比（或按设置留空）。
        let gap: TrayRingGapStyle
        let accessory: TrayRingAccessory?
        if battery.charging {
            gap = .indicator
            accessory = .symbol(TrayIconSymbolState(
                symbolNames: [],
                color: .primary,
                scale: TrayIconRenderer.defaultTextScale
            ))
        } else if battery.externalConnected,
                  !(options.showsPercentageWhenConnected && options.showsPercentage) {
            gap = .indicator
            accessory = .symbol(TrayIconSymbolState(
                symbolNames: ["powerplug.portrait.fill", "powerplug.fill", "bolt.fill"],
                color: .primary,
                scale: TrayIconRenderer.defaultTextScale
            ))
        } else if options.showsPercentage {
            gap = .value
            accessory = .text(TrayIconTextState(
                text: "\(battery.soc)",
                color: .primary,
                scale: TrayIconRenderer.defaultTextScale
            ))
        } else {
            gap = .closed
            accessory = nil
        }

        return TrayOuterRing(
            segments: [TrayRingSegment(progress: Double(battery.soc) / 100, color: role)],
            gap: gap,
            accessory: accessory
        )
    }

    // MARK: - 中心符号（网络 / 蓝牙音频）

    private static func centerState(
        network: NetworkSnapshot?,
        volume: VolumeSnapshot?,
        options: TrayIconOptions
    ) -> TrayCenter {
        if options.replacesNetworkIconWithBluetoothAudio,
           volume?.isBluetooth == true {
            let name = volume?.deviceName ?? ""
            let symbols: [String] = name.localizedCaseInsensitiveContains("AirPods")
                ? ["airpods", "headphones"]
                : ["headphones", "hifispeaker"]
            return .symbol(TrayIconSymbolState(
                symbolNames: symbols,
                color: .bluetooth
            ))
        }

        guard let network else {
            return .symbol(TrayIconSymbolState(
                symbolNames: ["wifi.slash", "wifi"],
                color: .primary
            ))
        }

        if network.connection == .ethernet {
            return .symbol(TrayIconSymbolState(
                symbolNames: ["cable.connector", "network"],
                color: .primary
            ))
        }

        switch network.wifi {
        case .connected:
            let bars = network.bars
            let variableValue: Double
            switch bars {
            case 3: variableValue = 1
            case 2: variableValue = 0.66
            case 1: variableValue = 0.33
            default: variableValue = 0
            }
            return .symbol(TrayIconSymbolState(
                symbolNames: ["wifi"],
                variableValue: variableValue,
                color: bars == 0 ? .inactive : .primary
            ))
        case .notAssociated:
            return .symbol(TrayIconSymbolState(
                symbolNames: ["wifi"],
                variableValue: 0,
                color: .primary
            ))
        case .noInternet:
            return .symbol(TrayIconSymbolState(
                symbolNames: ["wifi.exclamationmark", "wifi"],
                color: .primary
            ))
        case .off, .unavailable:
            return .symbol(TrayIconSymbolState(
                symbolNames: ["wifi.slash", "wifi"],
                color: .primary
            ))
        }
    }

    // MARK: - 底部（音量）

    private static func volumeFooter(
        _ volume: VolumeSnapshot?,
        options: TrayIconOptions
    ) -> TrayFooter? {
        // 与 status-trio 一致：音量指示始终存在，未知音量按 0 绘制，
        // 图标高度与位置保持稳定。
        let scalar = volume?.scalar.map { min(1, max(0, $0)) }
        let isMuted = volume?.isMuted ?? false
        let isBluetooth = volume?.isBluetooth ?? false
        let mayUseBluetoothColor = options.usesBluetoothVolumeColor && isBluetooth

        switch options.volumeStyle {
        case .dots:
            let steps = volumeSteps(scalar: scalar, isMuted: isMuted) ?? 0
            let color: TrayIconColorRole = mayUseBluetoothColor && steps > 0 ? .bluetooth : .primary
            return .dots(TrayFooterDots(count: 4, activeCount: steps, color: color))
        case .arc:
            let progress = isMuted ? 0 : (scalar ?? 0)
            let color: TrayIconColorRole = mayUseBluetoothColor && progress > 0 ? .bluetooth : .primary
            return .arc(TrayFooterArc(progress: progress, color: color))
        }
    }

    /// 0...4 档，阈值与 status-trio 一致。
    static func volumeSteps(scalar: Double?, isMuted: Bool) -> Int? {
        guard let scalar else { return nil }
        let clamped = min(1, max(0, scalar))
        if isMuted || clamped == 0 { return 0 }
        if clamped <= 0.25 { return 1 }
        if clamped <= 0.50 { return 2 }
        if clamped <= 0.75 { return 3 }
        return 4
    }
}

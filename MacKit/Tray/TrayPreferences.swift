//
//  TrayPreferences.swift
//  MacKit
//
//  托盘图标偏好，对标 status-trio 的 BatteryIconOptions / VolumeIconOptions：
//    - 图标尺寸
//    - 是否显示电量百分比 / 插电时是否显示百分比
//    - 是否使用电池状态颜色
//    - 音量样式（圆点 / 弧线）
//    - 蓝牙音频替换网络图标、蓝牙音量变蓝
//

import Combine
import Foundation

@MainActor
final class TrayPreferences: ObservableObject {
    static let iconSizeRange: ClosedRange<Double> = 16...32
    static let defaultIconSize: Double = 24

    private enum Keys {
        static let iconSize = "trayIconSize"
        static let showsPercentage = "trayShowsPercentage"
        static let showsPercentageWhenConnected = "trayShowsPercentageWhenConnected"
        static let usesStatusColors = "trayUsesStatusColors"
        static let volumeStyle = "trayVolumeStyle"
        static let replacesNetworkIconWithBluetoothAudio = "trayReplacesNetworkIconWithBluetoothAudio"
        static let usesBluetoothVolumeColor = "trayUsesBluetoothVolumeColor"
    }

    private let defaults: UserDefaults

    /// 菜单栏图标边长（点）。
    @Published var iconSize: Double {
        didSet {
            let clamped = Self.clampIconSize(iconSize)
            if clamped != iconSize {
                iconSize = clamped
                return
            }
            defaults.set(iconSize, forKey: Keys.iconSize)
        }
    }

    /// 在顶部缺口显示电量百分比。
    @Published var showsPercentage: Bool {
        didSet {
            defaults.set(showsPercentage, forKey: Keys.showsPercentage)
        }
    }

    /// 插电（未充电）时也显示百分比，而不是插头符号。
    @Published var showsPercentageWhenConnected: Bool {
        didSet {
            defaults.set(showsPercentageWhenConnected, forKey: Keys.showsPercentageWhenConnected)
        }
    }

    /// 低电量 / 低电量模式 / 充电时使用状态颜色。
    @Published var usesStatusColors: Bool {
        didSet {
            defaults.set(usesStatusColors, forKey: Keys.usesStatusColors)
        }
    }

    /// 底部音量的绘制样式。
    @Published var volumeStyle: TrayVolumeStyle {
        didSet {
            defaults.set(volumeStyle.rawValue, forKey: Keys.volumeStyle)
        }
    }

    /// 蓝牙音频播放时用设备符号替换网络图标。
    @Published var replacesNetworkIconWithBluetoothAudio: Bool {
        didSet {
            defaults.set(
                replacesNetworkIconWithBluetoothAudio,
                forKey: Keys.replacesNetworkIconWithBluetoothAudio
            )
        }
    }

    /// 蓝牙音频播放时音量圆点 / 弧线转蓝。
    @Published var usesBluetoothVolumeColor: Bool {
        didSet {
            defaults.set(usesBluetoothVolumeColor, forKey: Keys.usesBluetoothVolumeColor)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedSize = (defaults.object(forKey: Keys.iconSize) as? NSNumber)?.doubleValue
        iconSize = Self.clampIconSize(storedSize ?? Self.defaultIconSize)
        showsPercentage = defaults.object(forKey: Keys.showsPercentage) as? Bool ?? true
        showsPercentageWhenConnected =
            defaults.object(forKey: Keys.showsPercentageWhenConnected) as? Bool ?? false
        usesStatusColors = defaults.object(forKey: Keys.usesStatusColors) as? Bool ?? true
        let storedVolumeStyle = defaults.object(forKey: Keys.volumeStyle) as? String
        volumeStyle = storedVolumeStyle.flatMap { TrayVolumeStyle(rawValue: $0) } ?? .dots
        replacesNetworkIconWithBluetoothAudio =
            defaults.object(forKey: Keys.replacesNetworkIconWithBluetoothAudio) as? Bool ?? false
        usesBluetoothVolumeColor =
            defaults.object(forKey: Keys.usesBluetoothVolumeColor) as? Bool ?? false
    }

    var iconOptions: TrayIconOptions {
        TrayIconOptions(
            showsPercentage: showsPercentage,
            showsPercentageWhenConnected: showsPercentageWhenConnected,
            usesStatusColors: usesStatusColors,
            volumeStyle: volumeStyle,
            replacesNetworkIconWithBluetoothAudio: replacesNetworkIconWithBluetoothAudio,
            usesBluetoothVolumeColor: usesBluetoothVolumeColor
        )
    }

    private static func clampIconSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultIconSize }
        return min(iconSizeRange.upperBound, max(iconSizeRange.lowerBound, value))
    }
}

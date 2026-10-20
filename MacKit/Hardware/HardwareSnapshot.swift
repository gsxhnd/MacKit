//
//  HardwareSnapshot.swift
//  MacKit
//
//  SMC 风扇与温度传感器的数据模型。
//

import Foundation

nonisolated enum FanMode: UInt8, Sendable {
    case auto = 0
    case manual = 1
    case system = 3
    case unknown = 255

    init(raw: UInt8) {
        self = FanMode(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .auto: "自动"
        case .manual: "手动"
        case .system: "系统接管"
        case .unknown: "未知"
        }
    }
}

nonisolated struct FanInfo: Sendable, Equatable, Identifiable {
    var index: Int
    var actualRPM: Double?
    var targetRPM: Double?
    var minimumRPM: Double?
    var maximumRPM: Double?
    var mode: FanMode

    var id: Int { index }

    var name: String { "风扇 \(index + 1)" }

    var safeMinimum: Double { max(1000, minimumRPM ?? 1000) }
    var safeMaximum: Double { max(safeMinimum, maximumRPM ?? 7000) }

    var fraction: Double {
        guard safeMaximum > safeMinimum else { return 0 }
        return min(1, max(0, ((actualRPM ?? 0) - safeMinimum) / (safeMaximum - safeMinimum)))
    }
}

nonisolated enum TemperatureGroup: String, Sendable, CaseIterable {
    case cpu
    case gpu
    case memory
    case storage
    case battery
    case system
    case display
    case power
    case other

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .storage: "存储"
        case .battery: "电池"
        case .system: "机身"
        case .display: "显示"
        case .power: "供电"
        case .other: "其他"
        }
    }

    var symbolName: String {
        switch self {
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

nonisolated struct TemperatureReading: Sendable, Equatable, Identifiable {
    var key: String
    var name: String
    var celsius: Double
    var group: TemperatureGroup

    var id: String { key }

    var formatted: String { String(format: "%.1f°", celsius) }
}

nonisolated struct HardwareSnapshot: Sendable, Equatable {
    var capturedAt: Date = .now
    var smcAvailable = false
    var note: String?

    var fans: [FanInfo] = []
    var sensors: [TemperatureReading] = []

    var cpuAverageC: Double?
    var cpuMaxC: Double?
    var cpuHotspotC: Double?
    var gpuAverageC: Double?
    var gpuMaxC: Double?
    var gpuHotspotC: Double?

    var memoryC: Double?
    var storageC: Double?
    var batteryC: Double?
    var ambientC: Double?
    var wifiC: Double?
    var packageC: Double?
    var vrmC: Double?

    var hottest: [TemperatureReading] = []

    static let empty = HardwareSnapshot()

    var fanRPMTotal: Double {
        fans.compactMap(\.actualRPM).reduce(0, +)
    }

    var cpuSensors: [TemperatureReading] {
        sensors.filter { $0.group == .cpu && ($0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te")) }
    }

    var gpuSensors: [TemperatureReading] {
        sensors.filter { $0.group == .gpu }
    }
}

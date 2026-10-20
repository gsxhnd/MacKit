//
//  BatterySnapshot.swift
//  MacKit
//
//  电池与电源数据模型。与 batt.sh 展示的字段一一对应。
//

import Foundation

// MARK: - 电源状态

nonisolated enum BatteryPowerState: Sendable {
    case unavailable
    case critical
    case charging
    case charged
    case pluggedNotCharging
    case discharging
}

// MARK: - 快照

nonisolated struct BatterySnapshot: Sendable, Equatable, Codable {
    var capturedAt: Date = .now
    var model: String = ""
    var osVersion: String = ""

    var batteryPresent = false
    var soc = 0
    var rawSOC: Int?
    var charging = false
    var charged = false
    var externalConnected = false
    var critical = false
    var lowPowerMode = false
    var registryAvailable = false
    var warning: String?

    var voltageV: Double?
    var amperageMA: Int?
    var temperatureC: Double?
    var cellVoltagesMV: [Int] = []
    var qmaxMAh: [Int] = []

    var currentCapacityMAh: Int?
    var fullChargeCapacityMAh: Int?
    var nominalCapacityMAh: Int?
    var designCapacityMAh: Int?
    var cycleCount: Int?
    var designCycleCount = 1000

    var hardwareSerial: String?
    var deviceName: String?
    var firmwareVersion: String?
    var gaugeHealth: String?
    var gaugeCondition: String?
    var manufactureDate: Date?

    var timeToEmptyMinutes: Int?
    var timeToFullMinutes: Int?

    var adapter: AdapterInfo?
    var charger: ChargerInfo?
    var power: PowerTelemetry?
    var lifetime: BatteryLifetime?
}

nonisolated struct AdapterInfo: Sendable, Equatable, Codable {
    var watts: Int?
    var voltageV: Double?
    var currentA: Double?
    var name: String?
    var isWireless = false
}

nonisolated struct ChargerInfo: Sendable, Equatable, Codable {
    var chargingVoltageV: Double?
    var chargingCurrentMA: Int?
}

nonisolated struct PowerTelemetry: Sendable, Equatable, Codable {
    var systemLoadW: Double?
    var systemPowerInW: Double?
    var adapterLossW: Double?
    var systemVoltageInV: Double?
    var batteryPowerW: Double?
}

nonisolated struct BatteryLifetime: Sendable, Equatable, Codable {
    var averageTemperatureC: Double?
    var minTemperatureC: Double?
    var maxTemperatureC: Double?
}

// MARK: - 派生信息

extension BatterySnapshot {
    var state: BatteryPowerState {
        guard batteryPresent else { return .unavailable }
        if critical { return .critical }
        if charging { return .charging }
        if charged && externalConnected { return .charged }
        if externalConnected { return .pluggedNotCharging }
        return .discharging
    }

    var stateTitle: String {
        switch state {
        case .unavailable: "未检测到电池"
        case .critical: "电量严重不足"
        case .charging: "充电中"
        case .charged: "已充满（维持满电）"
        case .pluggedNotCharging: "插电未充电（优化充电 / 养护模式）"
        case .discharging: "放电中（电池供电）"
        }
    }

    var sourceTitle: String {
        externalConnected ? "AC 适配器" : "电池"
    }

    /// 电池侧功率，正值为充入，负值为输出。
    var powerW: Double? {
        guard let voltageV, let amperageMA else { return nil }
        return voltageV * Double(amperageMA) / 1000
    }

    /// 满充容量相对设计容量的保持率。
    var healthPercent: Int? {
        guard let fullChargeCapacityMAh, let designCapacityMAh,
              fullChargeCapacityMAh > 0, designCapacityMAh > 0 else { return nil }
        let value = Int((Double(fullChargeCapacityMAh) / Double(designCapacityMAh) * 100).rounded())
        return min(100, max(0, value))
    }

    var cycleRemaining: Int? {
        guard let cycleCount else { return nil }
        return max(0, designCycleCount - cycleCount)
    }

    var adapterLoadPercent: Int? {
        guard let input = power?.systemPowerInW, input > 0,
              let watts = adapter?.watts, watts > 0 else { return nil }
        return min(100, Int((input / Double(watts) * 100).rounded()))
    }

    var healthConditionText: String? {
        if let condition = gaugeCondition?.trimmed, !condition.isEmpty {
            return Self.localizedHealth(condition)
        }
        if let health = gaugeHealth?.trimmed, !health.isEmpty {
            return Self.localizedHealth(health)
        }
        return nil
    }

    /// 预计续航 / 充满时间。优先使用系统估算，缺失时用容量与电流推算。
    var etaText: String {
        guard batteryPresent else { return "—" }

        if charging {
            if let minutes = timeToFullMinutes, minutes > 0 {
                return "约 \(minutes) 分钟充满"
            }
            if let current = currentCapacityMAh,
               let full = fullChargeCapacityMAh,
               let amperageMA, amperageMA > 0, full > current {
                let minutes = Int((Double(full - current) / Double(amperageMA) * 60).rounded(.up))
                if minutes > 0 && minutes <= 600 {
                    return "约 \(minutes) 分钟充满"
                }
            }
            return charged ? "已充满" : "即将充满"
        }

        if externalConnected {
            return charged ? "已充满" : "已接电源（未充电）"
        }

        if let minutes = timeToEmptyMinutes, minutes > 0 {
            return "约 \(minutes) 分钟耗尽"
        }
        if let current = currentCapacityMAh, let amperageMA, amperageMA < 0 {
            let minutes = Int((Double(current) / Double(-amperageMA) * 60).rounded(.up))
            if minutes > 0 && minutes <= 2880 {
                return "约 \(minutes) 分钟耗尽"
            }
        }
        return "估算中"
    }

    private static func localizedHealth(_ raw: String) -> String {
        switch raw.lowercased() {
        case "good", "normal": "正常"
        case "fair": "一般"
        case "poor": "较差"
        case "service recommended", "service battery": "建议维修"
        default: raw
        }
    }
}

// MARK: - 展示格式化

nonisolated enum BatteryFormat {
    static func number(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.grouping(.automatic))
    }

    static func capacity(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.grouping(.automatic))) mAh"
    }

    static func watts(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return "—" }
        return String(format: signed && value > 0 ? "+%.2f W" : "%.2f W", value)
    }

    static func volts(_ value: Double?, fractionDigits: Int = 2) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(fractionDigits)f V", value)
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f °C", value)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

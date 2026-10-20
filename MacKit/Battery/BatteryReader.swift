//
//  BatteryReader.swift
//  MacKit
//
//  直接通过 IOKit / IOPS 读取电池数据，避免在 App Sandbox 中执行 ioreg、pmset。
//

import Darwin
import Foundation
import IOKit
import IOKit.ps

nonisolated enum BatteryReader {
    static func read() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.capturedAt = Date()
        snapshot.model = hardwareModel()
        snapshot.osVersion = operatingSystemVersion()
        snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        let hasPowerSource = applyPowerSource(to: &snapshot)
        if let properties = registryProperties() {
            snapshot.registryAvailable = true
            applyRegistry(properties, to: &snapshot)
        } else {
            snapshot.registryAvailable = false
            if hasPowerSource {
                snapshot.warning = "无法读取 AppleSmartBattery 的详细数据，当前仅显示系统电源摘要。"
            }
        }

        if !snapshot.batteryPresent {
            snapshot.soc = 0
            snapshot.charging = false
            snapshot.charged = false
            snapshot.externalConnected = false
        }
        return snapshot
    }

    // MARK: - IOPS 电源摘要

    private static func applyPowerSource(to snapshot: inout BatterySnapshot) -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard (description.stringValue("Type") ?? "") == "InternalBattery" else { continue }

            snapshot.batteryPresent = description.boolValue("Is Present") ?? true
            snapshot.soc = description.intValue("Current Capacity") ?? snapshot.soc
            snapshot.charging = description.boolValue("Is Charging") ?? false
            snapshot.charged = description.boolValue("Is Charged") ?? false
            snapshot.externalConnected = (description.stringValue("Power Source State") ?? "") == "AC Power"
            snapshot.lowPowerMode = description.boolValue("LPM Active") ?? snapshot.lowPowerMode
            snapshot.gaugeHealth = description.stringValue("BatteryHealth")
            snapshot.gaugeCondition = description.stringValue("BatteryHealthCondition")
            if let serial = description.stringValue("Hardware Serial Number"), !serial.isEmpty {
                snapshot.hardwareSerial = serial
            }

            if let minutes = description.intValue("Time to Empty"), (1...2880).contains(minutes) {
                snapshot.timeToEmptyMinutes = minutes
            }
            if let minutes = description.intValue("Time to Full Charge"), (1...600).contains(minutes) {
                snapshot.timeToFullMinutes = minutes
            }
            return true
        }
        return false
    }

    // MARK: - AppleSmartBattery

    private static func registryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return properties
    }

    private static func applyRegistry(_ properties: [String: Any], to snapshot: inout BatterySnapshot) {
        if let value = properties.intValue("CurrentCapacity") {
            snapshot.soc = value
            snapshot.batteryPresent = true
        }
        if let value = properties.boolValue("ExternalConnected") {
            snapshot.externalConnected = value
        }
        if let value = properties.boolValue("IsCharging") {
            snapshot.charging = value
        }
        if let value = properties.boolValue("FullyCharged") {
            snapshot.charged = value
        }
        if let value = properties.boolValue("AtCriticalLevel") {
            snapshot.critical = value
        }

        if let millivolts = properties.intValue("Voltage") ?? properties.intValue("AppleRawBatteryVoltage"),
           (500...30000).contains(millivolts) {
            snapshot.voltageV = Double(millivolts) / 1000
        }
        if let amperage = properties.intValue("Amperage") ?? properties.intValue("InstantAmperage"),
           (-30000...30000).contains(amperage) {
            snapshot.amperageMA = amperage
        }
        if let value = properties.intValue("Temperature"), (0...12000).contains(value), value > 0 {
            snapshot.temperatureC = Double(value) / 100
        }

        if let value = properties.intValue("AppleRawCurrentCapacity"), value > 0 {
            snapshot.currentCapacityMAh = value
        }
        if let value = properties.intValue("AppleRawMaxCapacity"), value > 0 {
            snapshot.fullChargeCapacityMAh = value
        }
        if let value = properties.intValue("NominalChargeCapacity"), value > 0 {
            snapshot.nominalCapacityMAh = value
        }
        if let value = properties.intValue("DesignCapacity"), value > 0 {
            snapshot.designCapacityMAh = value
        }
        if let value = properties.intValue("CycleCount"), value >= 0 {
            snapshot.cycleCount = value
        }
        if let value = properties.intValue("DesignCycleCount9C"), value > 0 {
            snapshot.designCycleCount = value
        }
        if let value = properties.intValue("GasGaugeFirmwareVersion") {
            snapshot.firmwareVersion = String(value)
        }
        if let value = properties.stringValue("Serial"), !value.isEmpty {
            snapshot.hardwareSerial = value
        }
        if let value = properties.stringValue("DeviceName"), !value.isEmpty {
            snapshot.deviceName = value
        }
        if let minutes = properties.intValue("AvgTimeToEmpty"), (1...2880).contains(minutes) {
            snapshot.timeToEmptyMinutes = minutes
        }
        if let minutes = properties.intValue("AvgTimeToFull"), (1...600).contains(minutes) {
            snapshot.timeToFullMinutes = minutes
        }
        snapshot.manufactureDate = parseManufactureDate(properties.intValue("ManufactureDate"))

        // BatteryData 中包含电量计、电芯、Qmax 与历史温度等细节。
        if let batteryData = properties.dictionaryValue("BatteryData") {
            if let value = batteryData.intValue("StateOfCharge") {
                snapshot.rawSOC = value
            }
            if snapshot.cycleCount == nil, let value = batteryData.intValue("CycleCount") {
                snapshot.cycleCount = value
            }
            if snapshot.designCapacityMAh == nil, let value = batteryData.intValue("DesignCapacity") {
                snapshot.designCapacityMAh = value
            }
            if let cells = batteryData.intArrayValue("CellVoltage") {
                snapshot.cellVoltagesMV = cells
            }
            if let qmax = batteryData.intArrayValue("Qmax") {
                snapshot.qmaxMAh = qmax
            }
            if snapshot.manufactureDate == nil {
                snapshot.manufactureDate = parseManufactureDate(batteryData.intValue("ManufactureDate"))
            }
            if let lifetimeData = batteryData.dictionaryValue("LifetimeData") {
                snapshot.lifetime = BatteryLifetime(
                    averageTemperatureC: lifetimeData.intValue("AverageTemperature").map { Double($0) / 10 },
                    minTemperatureC: lifetimeData.intValue("MinimumTemperature").map(Double.init),
                    maxTemperatureC: lifetimeData.intValue("MaximumTemperature").map(Double.init)
                )
            }
        }

        // 充电器 / 适配器
        let adapterDictionary = properties.dictionaryValue("AdapterDetails")
            ?? (properties.arrayValue("AppleRawAdapterDetails")?.first as? [String: Any])
        if let adapter = adapterDictionary {
            snapshot.adapter = AdapterInfo(
                watts: adapter.intValue("Watts"),
                voltageV: adapter.intValue("AdapterVoltage").map { Double($0) / 1000 },
                currentA: adapter.intValue("Current").map { Double($0) / 1000 },
                name: adapter.stringValue("Description"),
                isWireless: adapter.boolValue("IsWireless") ?? false
            )
        }

        if let charger = properties.dictionaryValue("ChargerData") {
            snapshot.charger = ChargerInfo(
                chargingVoltageV: charger.intValue("ChargingVoltage").map { Double($0) / 1000 },
                chargingCurrentMA: charger.intValue("ChargingCurrent")
            )
        }

        if let telemetry = properties.dictionaryValue("PowerTelemetryData") {
            let systemLoad = telemetry.intValue("SystemLoad").map { Double($0) / 1000 }
            let systemPowerIn = telemetry.intValue("SystemPowerIn").map { Double($0) / 1000 }
            if (systemLoad ?? 0) > 0 || (systemPowerIn ?? 0) > 0 {
                snapshot.power = PowerTelemetry(
                    systemLoadW: systemLoad,
                    systemPowerInW: systemPowerIn,
                    adapterLossW: telemetry.intValue("AdapterEfficiencyLoss").map { Double($0) / 1000 },
                    systemVoltageInV: telemetry.intValue("SystemVoltageIn").map { Double($0) / 1000 },
                    batteryPowerW: telemetry.intValue("BatteryPower").map { Double($0) / 1000 }
                )
            }
        }
    }

    // MARK: - 系统信息

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }

    private static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func parseManufactureDate(_ raw: Int?) -> Date? {
        // 标准编码仅占 16 位；更大的值是厂商自定义格式，不能按 Apple 编码解读。
        guard let raw, raw > 0, raw <= 0xFFFF else { return nil }
        let day = raw & 0x1F
        let month = (raw >> 5) & 0x0F
        let year = ((raw >> 9) & 0x7F) + 1980
        guard (2000...2035).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day)
        )
    }
}

// MARK: - 类型宽松的 IORegistry 取值

extension Dictionary where Key == String, Value == Any {
    nonisolated func intValue(_ key: String) -> Int? {
        switch self[key] {
        case let value as Int: value
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
    }

    nonisolated func boolValue(_ key: String) -> Bool? {
        switch self[key] {
        case let value as Bool: value
        case let value as String:
            switch value.lowercased() {
            case "yes", "true", "1": true
            case "no", "false", "0": false
            default: nil
            }
        case let value as NSNumber: value.boolValue
        default: nil
        }
    }

    nonisolated func stringValue(_ key: String) -> String? {
        switch self[key] {
        case let value as String: value
        case let value as NSString: value as String
        default: nil
        }
    }

    nonisolated func dictionaryValue(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    nonisolated func arrayValue(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    nonisolated func intArrayValue(_ key: String) -> [Int]? {
        if let values = self[key] as? [Int] { return values }
        guard let values = self[key] as? [Any] else { return nil }
        return values.compactMap { value in
            switch value {
            case let value as Int: value
            case let value as NSNumber: value.intValue
            default: nil
            }
        }
    }
}

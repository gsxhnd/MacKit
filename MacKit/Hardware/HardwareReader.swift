//
//  HardwareReader.swift
//  MacKit
//
//  读取 AppleSMC 的风扇状态与温度传感器（只读）。
//

import Foundation

actor HardwareReader {
    private let smc: SMCConnection?
    private var sensorDefinitions: [SensorDefinition]?
    private var fanDefinitions: [FanDefinition]?

    init() {
        smc = try? SMCConnection()
    }

    func read() -> HardwareSnapshot {
        guard let smc else {
            var empty = HardwareSnapshot.empty
            empty.note = "无法连接 AppleSMC，温度与风扇数据不可用"
            return empty
        }

        ensureCatalog(smc: smc)

        var snapshot = HardwareSnapshot()
        snapshot.capturedAt = Date()
        snapshot.smcAvailable = true

        snapshot.fans = (fanDefinitions ?? []).map { fan in
            FanInfo(
                index: fan.index,
                actualRPM: try? smc.readFloat(fan.actualKey),
                targetRPM: try? smc.readFloat(fan.targetKey),
                minimumRPM: try? smc.readFloat(fan.minimumKey),
                maximumRPM: try? smc.readFloat(fan.maximumKey),
                mode: (fan.modeKey.flatMap { try? smc.readUInt8($0) }).map(FanMode.init(raw:)) ?? .unknown
            )
        }

        var sensors: [TemperatureReading] = []
        for definition in sensorDefinitions ?? [] {
            guard let value = try? smc.readFloat(definition.key),
                  value > 10, value < 125 else { continue }
            sensors.append(
                TemperatureReading(
                    key: definition.key,
                    name: definition.name,
                    celsius: value,
                    group: definition.group
                )
            )
        }
        snapshot.sensors = sensors.sorted {
            if $0.group != $1.group {
                return groupOrder($0.group) < groupOrder($1.group)
            }
            return $0.key < $1.key
        }

        let byKey = Dictionary(uniqueKeysWithValues: snapshot.sensors.map { ($0.key, $0.celsius) })
        let cpu = snapshot.sensors.filter {
            $0.group == .cpu && ($0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te"))
        }
        let gpu = snapshot.sensors.filter { $0.group == .gpu }

        snapshot.cpuAverageC = average(cpu.map(\.celsius))
        snapshot.cpuMaxC = cpu.map(\.celsius).max()
        snapshot.cpuHotspotC = byKey["TCMz"] ?? snapshot.cpuMaxC
        snapshot.gpuAverageC = average(gpu.map(\.celsius))
        snapshot.gpuMaxC = gpu.map(\.celsius).max()
        snapshot.gpuHotspotC = byKey["TRDX"] ?? snapshot.gpuMaxC

        snapshot.memoryC = byKey["TVm0"] ?? byKey["Tm0B"]
        snapshot.storageC = byKey["TH0x"] ?? byKey["TH0T"] ?? byKey["T5SP"]
        snapshot.batteryC = byKey["TB0T"] ?? byKey["TB1T"]
        snapshot.ambientC = byKey["TAOL"] ?? byKey["TA0P"]
        snapshot.wifiC = byKey["TW0P"]
        snapshot.packageC = byKey["TPMP"] ?? byKey["TPSP"]
        snapshot.vrmC = [
            "TVD0", "TVM0", "TVMC", "TVMr", "TMVR", "TVS0", "TVS1", "TVS2", "TVS3"
        ].compactMap { byKey[$0] }.max()

        snapshot.hottest = Array(
            snapshot.sensors
                .filter { $0.group != .battery }
                .sorted { $0.celsius > $1.celsius }
                .prefix(10)
        )

        return snapshot
    }

    // MARK: - 目录探测

    private func ensureCatalog(smc: SMCConnection) {
        guard sensorDefinitions == nil || fanDefinitions == nil else { return }

        if fanDefinitions == nil {
            fanDefinitions = Self.detectFans(smc: smc)
        }

        if sensorDefinitions == nil {
            var definitions: [String: SensorDefinition] = [:]

            for definition in Self.curatedSensors where smc.hasKey(definition.key) {
                definitions[definition.key] = definition
            }

            for definition in Self.scannedSensors where definitions[definition.key] == nil && smc.hasKey(definition.key) {
                definitions[definition.key] = definition
            }

            sensorDefinitions = definitions.values.sorted { $0.key < $1.key }
        }
    }

    private static func detectFans(smc: SMCConnection) -> [FanDefinition] {
        var count = 0
        if let raw = try? smc.readUInt8("FNum") {
            count = Int(raw)
        } else {
            for index in 0..<4 where smc.hasKey("F\(index)Ac") {
                count = index + 1
            }
        }
        guard count > 0 else { return [] }

        return (0..<count).compactMap { index in
            guard smc.hasKey("F\(index)Ac") else { return nil }
            let modeKey = smc.hasKey("F\(index)Md") ? "F\(index)Md"
                : (smc.hasKey("F\(index)md") ? "F\(index)md" : nil)
            return FanDefinition(
                index: index,
                actualKey: "F\(index)Ac",
                targetKey: "F\(index)Tg",
                minimumKey: "F\(index)Mn",
                maximumKey: "F\(index)Mx",
                modeKey: modeKey
            )
        }
    }

    // MARK: - 传感器目录

    private struct SensorDefinition {
        let key: String
        let name: String
        let group: TemperatureGroup
    }

    private struct FanDefinition {
        let index: Int
        let actualKey: String
        let targetKey: String
        let minimumKey: String
        let maximumKey: String
        let modeKey: String?
    }

    private static let curatedSensors: [SensorDefinition] = [
        .init(key: "TCMz", name: "CPU 热点", group: .cpu),
        .init(key: "TCMb", name: "CPU 核心最高", group: .cpu),
        .init(key: "TCHP", name: "CPU 供电附近", group: .cpu),
        .init(key: "TRDX", name: "GPU 热点", group: .gpu),
        .init(key: "TVD0", name: "显示供电 VRM", group: .power),
        .init(key: "TVM0", name: "内存供电 VRM", group: .power),
        .init(key: "TVMC", name: "内存 VRM 控制器", group: .power),
        .init(key: "TVMr", name: "内存 VRM", group: .power),
        .init(key: "TMVR", name: "内存 VRM", group: .power),
        .init(key: "TVA0", name: "辅助供电 VRM", group: .power),
        .init(key: "TVm0", name: "统一内存", group: .memory),
        .init(key: "Tm0B", name: "统一内存", group: .memory),
        .init(key: "TH0x", name: "NAND 闪存", group: .storage),
        .init(key: "TH0T", name: "NAND 闪存", group: .storage),
        .init(key: "TH0a", name: "NAND 闪存", group: .storage),
        .init(key: "TH0b", name: "NAND 闪存", group: .storage),
        .init(key: "T5SP", name: "SSD 控制器", group: .storage),
        .init(key: "Ts0P", name: "SSD 邻近", group: .storage),
        .init(key: "Ts1P", name: "SSD 邻近", group: .storage),
        .init(key: "TB0T", name: "电池 1", group: .battery),
        .init(key: "TB1T", name: "电池 2", group: .battery),
        .init(key: "TB2T", name: "电池 3", group: .battery),
        .init(key: "TAOL", name: "机身风道", group: .system),
        .init(key: "TA0P", name: "环境", group: .system),
        .init(key: "TW0P", name: "Wi-Fi 模块", group: .system),
        .init(key: "TIOP", name: "雷雳控制器", group: .system),
        .init(key: "TPMP", name: "SoC 封装", group: .system),
        .init(key: "TPSP", name: "SoC 表面", group: .system),
        .init(key: "TDBP", name: "屏幕背光", group: .display),
        .init(key: "TDeL", name: "屏幕左侧", group: .display),
        .init(key: "TDeR", name: "屏幕右侧", group: .display)
    ]

    private static let scannedSensors: [SensorDefinition] = {
        var definitions: [SensorDefinition] = []

        for value in 0...0x3F {
            let suffix = String(format: "%02X", value)
            definitions.append(.init(key: "Tp\(suffix)", name: "P 核 \(suffix)", group: .cpu))
            definitions.append(.init(key: "Tg\(suffix)", name: "GPU \(suffix)", group: .gpu))
        }
        for value in 0...0x0F {
            let suffix = String(format: "%02X", value)
            definitions.append(.init(key: "Te\(suffix)", name: "E 核 \(suffix)", group: .cpu))
            definitions.append(.init(key: "Ts0\(String(format: "%X", value))", name: "SoC \(String(format: "%X", value))", group: .system))
            definitions.append(.init(key: "Ts1\(String(format: "%X", value))", name: "SoC \(String(format: "%X", value))", group: .system))
            definitions.append(.init(key: "TRD\(String(format: "%X", value))", name: "GPU \(String(format: "%X", value))", group: .gpu))
            definitions.append(.init(key: "TPD\(String(format: "%X", value))", name: "SoC 封装 \(String(format: "%X", value))", group: .system))
            definitions.append(.init(key: "TVS\(String(format: "%X", value))", name: "系统供电 \(String(format: "%X", value))", group: .power))
        }
        definitions.append(.init(key: "TRDX", name: "GPU 热点", group: .gpu))
        return definitions
    }()

    private func groupOrder(_ group: TemperatureGroup) -> Int {
        TemperatureGroup.allCases.firstIndex(of: group) ?? 99
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

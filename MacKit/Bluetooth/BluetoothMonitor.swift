//
//  BluetoothMonitor.swift
//  MacKit
//
//  蓝牙设备监控：通过 system_profiler 读取已连接设备与电量。
//
//  对齐 status-trio 的 BluetoothBatteryReader / BluetoothPairedDeviceReader：
//  「已连接」集合优先，地址相同的设备只保留一条。
//

import Combine
import Foundation
import IOBluetooth
import IOKit

nonisolated enum BluetoothDeviceKind: Equatable, Sendable {
    case headphones
    case speaker
    case mouse
    case keyboard
    case other

    var symbolName: String {
        switch self {
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker"
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    var title: String {
        switch self {
        case .headphones: return "耳机"
        case .speaker: return "扬声器"
        case .mouse: return "鼠标"
        case .keyboard: return "键盘"
        case .other: return "设备"
        }
    }
}

nonisolated struct BluetoothDeviceInfo: Identifiable, Equatable, Sendable {
    /// 归一化后的设备地址。
    let id: String
    let name: String
    let kind: BluetoothDeviceKind
    let isConnected: Bool
    let batteryMain: Int?
    let batteryLeft: Int?
    let batteryRight: Int?
    let batteryCase: Int?

    /// 例如 `L 80% · R 75%` / `65%`。
    var batterySummary: String? {
        var parts: [String] = []
        if let batteryMain { parts.append("\(batteryMain)%") }
        if let batteryLeft { parts.append("L \(batteryLeft)%") }
        if let batteryRight { parts.append("R \(batteryRight)%") }
        if let batteryCase { parts.append("盒 \(batteryCase)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor
final class BluetoothMonitor: ObservableObject {
    /// 所有已配对设备（已连接在前）。
    @Published private(set) var pairedDevices: [BluetoothDeviceInfo] = []
    /// 正在连接 / 断开的设备地址。
    @Published private(set) var pendingAddress: String?

    var connectedDevices: [BluetoothDeviceInfo] {
        pairedDevices.filter(\.isConnected)
    }

    private let queue = DispatchQueue(label: "MacKit.BluetoothMonitor", qos: .utility)
    private var timer: Timer?
    private var isReading = false

    func start() {
        guard timer == nil else { return }
        refreshNow()
        // system_profiler 较重，轮询间隔放长；打开面板时会主动刷新。
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNow()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        guard !isReading else { return }
        isReading = true
        queue.async { [weak self] in
            let parsed = BluetoothMonitor.readDevices()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReading = false
                if let parsed {
                    self.pairedDevices = parsed
                }
            }
        }
    }

    /// 连接 / 断开已配对的蓝牙设备（对齐 status-trio 的 IOBluetooth 实现）。
    func setConnected(_ device: BluetoothDeviceInfo, connected: Bool) {
        guard pendingAddress == nil else { return }
        pendingAddress = device.id
        TrayLog.write("bluetooth: \(connected ? "connect" : "disconnect") \(device.name)")

        let address = Self.normalizedAddress(device.id)
        queue.async { [weak self] in
            let targets = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let target = targets.first {
                Self.normalizedAddress($0.addressString ?? "") == address
            }
            let status = connected ? target?.openConnection() : target?.closeConnection()
            let accepted = status == kIOReturnSuccess

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingAddress = nil
                guard accepted else { return }
                // 给系统一点时间更新设备状态与音频输出列表。
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.refreshNow()
            }
        }
    }

    /// 地址归一化：`AC:90:85:C2:9C:1F` 与 `ac-90-85-c2-9c-1f` 视为同一设备。
    nonisolated static func normalizedAddress(_ address: String) -> String {
        address
            .uppercased()
            .filter { $0.isHexDigit }
    }

    // MARK: - 系统读取

    private nonisolated static func readDevices() -> [BluetoothDeviceInfo]? {
        guard let data = runProfiler() else { return nil }
        return parse(json: data)
    }

    private nonisolated static func runProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPBluetoothDataType"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private nonisolated static func parse(json: Data) -> [BluetoothDeviceInfo]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let value = root["SPBluetoothDataType"] else {
            return nil
        }

        let sections: [[String: Any]]
        if let list = value as? [[String: Any]] {
            sections = list
        } else if let single = value as? [String: Any] {
            sections = [single]
        } else {
            return nil
        }

        var devices: [BluetoothDeviceInfo] = []
        var listedAddresses: Set<String> = []

        for section in sections {
            for (collectionKey, isConnected) in [
                ("device_connected", true),
                ("device_not_connected", false)
            ] {
                guard let entries = section[collectionKey] as? [[String: Any]] else { continue }
                for entry in entries {
                    for (name, raw) in entry {
                        guard let properties = raw as? [String: Any],
                              let address = properties["device_address"] as? String,
                              !address.isEmpty,
                              !name.isEmpty else {
                            continue
                        }
                        let key = normalizedAddress(address)
                        guard listedAddresses.insert(key).inserted else { continue }

                        devices.append(BluetoothDeviceInfo(
                            id: key,
                            name: name,
                            kind: kind(from: properties),
                            isConnected: isConnected,
                            batteryMain: percentage(properties["device_batteryLevelMain"])
                                ?? percentage(properties["device_batteryLevel"]),
                            batteryLeft: percentage(properties["device_batteryLevelLeft"]),
                            batteryRight: percentage(properties["device_batteryLevelRight"]),
                            batteryCase: percentage(properties["device_batteryLevelCase"])
                        ))
                    }
                }
            }
        }
        // 已连接优先，其次是音频类设备，方便在托盘里直接切换。
        return devices.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            let leftAudio = lhs.kind == .headphones || lhs.kind == .speaker
            let rightAudio = rhs.kind == .headphones || rhs.kind == .speaker
            if leftAudio != rightAudio { return leftAudio }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private nonisolated static func kind(from properties: [String: Any]) -> BluetoothDeviceKind {
        let raw = [
            properties["device_minorType"],
            properties["device_minorClassOfDevice_string"],
            properties["device_majorType"]
        ]
        .compactMap { $0 as? String }
        .joined(separator: " ")
        .lowercased()

        if raw.contains("headphone") || raw.contains("airpods") {
            return .headphones
        }
        if raw.contains("speaker") {
            return .speaker
        }
        if raw.contains("mouse") || raw.contains("trackpad") {
            return .mouse
        }
        if raw.contains("keyboard") {
            return .keyboard
        }
        return .other
    }

    private nonisolated static func percentage(_ value: Any?) -> Int? {
        let number: Double
        switch value {
        case let value as NSNumber:
            number = value.doubleValue
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutPercent = trimmed.hasSuffix("%")
                ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
            guard let parsed = Double(withoutPercent) else { return nil }
            number = parsed
        default:
            return nil
        }

        guard number.isFinite, number.rounded() == number, (0...100).contains(number) else {
            return nil
        }
        return Int(number)
    }
}

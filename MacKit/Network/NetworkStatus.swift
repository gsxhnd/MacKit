//
//  NetworkStatus.swift
//  MacKit
//
//  网络状态模型，对齐 status-trio 的 WiFiStatus / NetworkConnection。
//

import Foundation

// MARK: - Wi-Fi 状态

nonisolated enum WiFiState: Equatable, Sendable {
    /// 没有 Wi-Fi 硬件。
    case unavailable
    /// Wi-Fi 已关闭。
    case off
    /// Wi-Fi 打开但未加入网络。
    case notAssociated
    /// 已加入网络，但路径不可达。
    case noInternet
    /// 已连接且可上网。
    case connected
}

// MARK: - 连接类型

nonisolated enum NetworkConnectionType: Equatable, Sendable {
    case wifi
    case ethernet
    case none
}

// MARK: - 快照

nonisolated struct NetworkSnapshot: Equatable, Sendable {
    var wifi: WiFiState = .unavailable
    var ssid: String?
    var rssi: Int?
    var connection: NetworkConnectionType = .none

    /// 已加入某个 Wi-Fi 网络（信号格有意义的场景）。
    var isWiFiAssociated: Bool {
        wifi == .connected || wifi == .noInternet
    }

    /// 0...3 的信号格数，映射规则与 status-trio 一致。
    var bars: Int {
        Self.wifiBars(rssi: rssi)
    }

    var signalText: String {
        guard isWiFiAssociated else { return "—" }
        guard let rssi else { return "信号未知" }
        switch bars {
        case 3: return "信号强（\(rssi) dBm）"
        case 2: return "信号中（\(rssi) dBm）"
        case 1: return "信号弱（\(rssi) dBm）"
        default: return "无信号（\(rssi) dBm）"
        }
    }

    static func wifiBars(rssi: Int?) -> Int {
        guard let rssi else { return 0 }
        switch rssi {
        case (-60)...: return 3
        case -78 ... -61: return 2
        case -88 ... -79: return 1
        default: return 0
        }
    }
}

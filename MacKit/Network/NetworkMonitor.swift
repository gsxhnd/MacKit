//
//  NetworkMonitor.swift
//  MacKit
//
//  网络监控：NWPathMonitor 负责连接类型与可达性，
//  CoreWLAN 负责 Wi-Fi 开关 / SSID / 信号强度。
//
//  对齐 status-trio：
//    - Wi-Fi 状态机：off / notAssociated / noInternet / connected / unavailable
//    - 信号格阈值 3 / 2 / 1 / 0
//

import Combine
import CoreWLAN
import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var snapshot = NetworkSnapshot()

    /// CoreWLAN 读取是同步 IPC，放到串行队列，避免阻塞主线程。
    private let queue = DispatchQueue(label: "MacKit.NetworkMonitor", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var started = false

    private var path = PathState()
    private var wifi = WiFiReading()

    func start() {
        guard !started else { return }
        started = true

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let state = PathState(
                satisfied: path.status == .satisfied,
                wired: path.usesInterfaceType(.wiredEthernet),
                wireless: path.usesInterfaceType(.wifi)
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.path = state
                self.recompute()
            }
        }
        pathMonitor.start(queue: queue)

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWiFi()
            }
        }
        refreshWiFi()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
        started = false
    }

    func refreshNow() {
        refreshWiFi()
    }

    // MARK: - 读取

    private func refreshWiFi() {
        queue.async { [weak self] in
            let reading = NetworkMonitor.readWiFi()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wifi = reading
                self.recompute()
            }
        }
    }

    /// 在后台队列执行：CoreWLAN 的读取是同步 IPC。
    private nonisolated static func readWiFi() -> WiFiReading {
        guard let interface = CWWiFiClient.shared().interface() else {
            return WiFiReading()
        }
        return WiFiReading(
            hasInterface: true,
            powerOn: interface.powerOn(),
            serviceActive: interface.serviceActive(),
            ssid: interface.ssid(),
            rssi: interface.rssiValue()
        )
    }

    // MARK: - 合成

    private func recompute() {
        var snapshot = NetworkSnapshot()
        snapshot.ssid = wifi.ssid
        snapshot.rssi = wifi.rssi

        if path.wired {
            snapshot.connection = .ethernet
        } else if path.wireless {
            snapshot.connection = .wifi
        } else {
            snapshot.connection = .none
        }

        // 分类规则与 status-trio 的 WiFiClassifier 一致：
        // 不以 SSID 是否可读判断关联状态（macOS 14+ 未授权定位时 SSID 为 nil）。
        if !wifi.hasInterface {
            snapshot.wifi = .unavailable
        } else if !wifi.powerOn {
            snapshot.wifi = .off
        } else if !wifi.serviceActive {
            snapshot.wifi = .notAssociated
        } else if !path.satisfied && snapshot.connection != .ethernet {
            snapshot.wifi = .noInternet
        } else {
            snapshot.wifi = .connected
        }

        if snapshot != self.snapshot {
            self.snapshot = snapshot
        }
    }
}

// MARK: - 内部读数

private nonisolated struct PathState {
    var satisfied = false
    var wired = false
    var wireless = false
}

private nonisolated struct WiFiReading {
    var hasInterface = false
    var powerOn = false
    var serviceActive = false
    var ssid: String?
    var rssi: Int?
}

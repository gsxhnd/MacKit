//
//  BatteryMonitor.swift
//  MacKit
//
//  电池、SMC 温度与风扇状态的统一监控层。
//

import AppKit
import Combine
import Foundation

@MainActor
final class BatteryMonitor: ObservableObject {
    enum RefreshRate: Int, CaseIterable, Identifiable {
        case one = 1
        case two = 2
        case five = 5
        case ten = 10

        var id: Int { rawValue }
        var label: String { "\(rawValue) 秒" }
    }

    enum FanPreset: String, CaseIterable, Identifiable {
        case quiet
        case balanced
        case maximum

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quiet: "静音"
            case .balanced: "平衡"
            case .maximum: "全速"
            }
        }

        var symbolName: String {
            switch self {
            case .quiet: "leaf.fill"
            case .balanced: "dial.medium.fill"
            case .maximum: "wind"
            }
        }
    }

    struct HistorySample: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let soc: Int
        let powerW: Double?
        let batteryTemperatureC: Double?
        let cpuTemperatureC: Double?
        let gpuTemperatureC: Double?
        let fanRPM: Double
    }

    @Published private(set) var snapshot: BatterySnapshot?
    @Published private(set) var hardware: HardwareSnapshot?
    @Published private(set) var history: [HistorySample] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    @Published private(set) var fanHelperState: FanHelperState = .inactive
    @Published private(set) var fanError: String?
    @Published private(set) var fanBusy = false
    @Published private(set) var manualFanControl = false
    @Published private(set) var fanTargets: [Int: Double] = [:]

    @Published var refreshRate: RefreshRate = .two {
        didSet {
            guard oldValue != refreshRate else { return }
            startPolling()
        }
    }

    @Published var isPaused = false {
        didSet {
            guard oldValue != isPaused else { return }
            startPolling()
        }
    }

    private let hardwareReader = HardwareReader()
    private let fanSocketPath = FanHelperInstaller.socketPath()
    private var fanClient: FanControlClient?
    private var pollingTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var thermalStrikes = 0

    init() {
        startPolling()
        observeSystemEvents()
    }

    // MARK: - 刷新

    func refreshNow() {
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let battery = Task.detached(priority: .utility) {
            BatteryReader.read()
        }.value
        async let hardware = hardwareReader.read()
        let (batterySnapshot, hardwareSnapshot) = await (battery, hardware)

        var snapshot = batterySnapshot
        snapshot.chargeLimit = ChargeLimitReader.chargeLimit()
        self.snapshot = snapshot
        self.hardware = hardwareSnapshot
        self.lastUpdated = snapshot.capturedAt

        appendHistory(battery: batterySnapshot, hardware: hardwareSnapshot)
        await maintainFanConnection()
        enforceThermalGuard(with: hardwareSnapshot)

    }

    private func appendHistory(battery: BatterySnapshot, hardware: HardwareSnapshot) {
        history.append(
            HistorySample(
                date: battery.capturedAt,
                soc: battery.soc,
                powerW: battery.powerW,
                batteryTemperatureC: battery.temperatureC,
                cpuTemperatureC: hardware.cpuHotspotC,
                gpuTemperatureC: hardware.gpuHotspotC,
                fanRPM: hardware.fanRPMTotal
            )
        )
        if history.count > 300 {
            history.removeFirst(history.count - 300)
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = nil

        guard !isPaused else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let self, !Task.isCancelled else { return }

                let interval = UInt64(self.refreshRate.rawValue) * 1_000_000_000
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func observeSystemEvents() {
        let powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }

        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }

        observers = [powerObserver, wakeObserver]
    }

    // MARK: - 风扇控制

    func enableFanControl() {
        guard !fanBusy else { return }
        fanBusy = true
        fanError = nil

        Task {
            await startFanHelperIfNeeded()
            fanBusy = false
        }
    }

    func setManualMode(_ enabled: Bool) {
        if !enabled {
            restoreAutoFans()
            return
        }
        guard !fanBusy else { return }

        fanBusy = true
        Task {
            defer { fanBusy = false }

            if !fanHelperState.isConnected {
                await startFanHelperIfNeeded()
            }
            guard fanHelperState.isConnected, let hardware else { return }

            manualFanControl = true
            thermalStrikes = 0
            fanError = nil
            if fanTargets.isEmpty {
                fanTargets = defaultFanTargets(from: hardware)
            }
            await applyAllFanTargets()
        }
    }

    func applyPreset(_ preset: FanPreset) {
        guard let hardware else { return }
        let targets = hardware.fans.reduce(into: [Int: Double]()) { result, fan in
            let minimum = fan.safeMinimum
            let maximum = fan.safeMaximum
            result[fan.index] = switch preset {
            case .quiet: minimum
            case .balanced: minimum + (maximum - minimum) * 0.45
            case .maximum: maximum
            }
        }
        fanTargets = targets

        if manualFanControl {
            Task { await applyAllFanTargets() }
        } else {
            guard !fanBusy else { return }
            fanBusy = true
            Task {
                defer { fanBusy = false }
                if !fanHelperState.isConnected {
                    await startFanHelperIfNeeded()
                }
                guard fanHelperState.isConnected else { return }
                manualFanControl = true
                thermalStrikes = 0
                fanError = nil
                await applyAllFanTargets()
            }
        }
    }

    func setFanTarget(index: Int, rpm: Double) {
        fanTargets[index] = rpm
    }

    func applyFanTarget(index: Int) {
        guard manualFanControl, let rpm = fanTargets[index] else { return }
        Task {
            guard await ensureFanHelperConnected() else { return }
            guard let client = fanClient else { return }
            let result = await client.apply(index: index, rpm: rpm)
            if !result.ok {
                fanError = result.message
            }
        }
    }

    func restoreAutoFans(reason: String? = nil) {
        manualFanControl = false
        fanTargets.removeAll()
        thermalStrikes = 0
        fanError = reason

        Task {
            guard let client = fanClient else { return }
            let result = await client.autoAll()
            if !result.ok, reason == nil {
                fanError = result.message
            }
        }
    }

    func clearFanError() {
        fanError = nil
    }

    func target(for fan: FanInfo) -> Double {
        fanTargets[fan.index] ?? max(fan.safeMinimum, fan.actualRPM ?? fan.safeMinimum)
    }

    private func defaultFanTargets(from hardware: HardwareSnapshot) -> [Int: Double] {
        hardware.fans.reduce(into: [Int: Double]()) { result, fan in
            result[fan.index] = max(fan.safeMinimum, min(fan.safeMaximum, fan.actualRPM ?? fan.safeMinimum))
        }
    }

    private func applyAllFanTargets() async {
        guard await ensureFanHelperConnected(), let client = fanClient else { return }
        var errors: [String] = []

        for fan in hardware?.fans ?? [] {
            guard let rpm = fanTargets[fan.index] else { continue }
            let result = await client.apply(index: fan.index, rpm: rpm)
            if !result.ok {
                errors.append("\(fan.name)：\(result.message)")
            }
        }

        if errors.isEmpty {
            fanError = nil
        } else {
            fanError = errors.joined(separator: "\n")
            manualFanControl = false
            fanTargets.removeAll()
            _ = await client.autoAll()
        }
    }

    private func ensureFanHelperConnected() async -> Bool {
        if fanHelperState.isConnected, fanClient != nil { return true }
        await startFanHelperIfNeeded()
        return fanHelperState.isConnected
    }

    private func startFanHelperIfNeeded() async {
        if fanHelperState.isConnected, fanClient != nil { return }
        if fanHelperState == .starting { return }

        fanHelperState = .starting
        if await connectExistingHelper() { return }

        do {
            try await FanHelperInstaller.installAndStart(socketPath: fanSocketPath)
        } catch {
            let message = (error as? FanHelperInstallError)?.description ?? error.localizedDescription
            fanHelperState = .failed(message)
            fanError = message
            return
        }

        for _ in 0..<24 {
            if await connectExistingHelper() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        fanHelperState = .failed("helper 未响应，请查看 \(FanHelperInstaller.logPath)")
        fanError = "helper 未响应，请查看 \(FanHelperInstaller.logPath)"
    }

    private func connectExistingHelper() async -> Bool {
        let client = FanControlClient(socketPath: fanSocketPath)
        guard await client.connect() else { return false }
        fanClient = client
        fanHelperState = .connected
        return true
    }

    private func maintainFanConnection() async {
        guard fanHelperState.isConnected, let client = fanClient else { return }
        let result = await client.ping()
        if !result.ok {
            fanHelperState = .failed(result.message)
            fanClient = nil
            if manualFanControl {
                manualFanControl = false
                fanTargets.removeAll()
                fanError = result.message
            }
        }
    }

    private func enforceThermalGuard(with hardware: HardwareSnapshot) {
        guard manualFanControl else {
            thermalStrikes = 0
            return
        }

        let hottest = max(hardware.cpuMaxC ?? 0, hardware.gpuMaxC ?? 0)
        guard hottest > 100 else {
            thermalStrikes = 0
            return
        }

        thermalStrikes += 1
        if thermalStrikes >= 2 {
            restoreAutoFans(reason: String(format: "温度达到 %.1f°C，已自动切回系统控制", hottest))
        }
    }
}

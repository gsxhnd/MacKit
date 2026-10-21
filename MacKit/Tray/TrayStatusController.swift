//
//  TrayStatusController.swift
//  MacKit
//
//  菜单栏状态项控制器。
//
//  交互对齐 lingyired/status-trio（Apache-2.0）：
//    - 左键：弹出状态面板（NSPopover）
//    - 右键（或 ⌃ + 左键）：弹出操作菜单
//    - 图标随监控数据与托盘偏好刷新；纯单色场景作为 template image
//      交给系统按 Space 实时着色
//

import AppKit
import Combine
import CoreAudio
import SwiftUI

@MainActor
final class TrayStatusController: NSObject, NSPopoverDelegate {
    private let monitor: BatteryMonitor
    private let network: NetworkMonitor
    private let volume: VolumeMonitor
    private let bluetooth: BluetoothMonitor
    private let preferences: TrayPreferences
    private var statusItem: NSStatusItem?
    private var appearanceObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    private let popover = NSPopover()
    /// 关闭后的短暂锁定，避免「点一下图标」被识别成「关闭后又打开」。
    private var lastPopoverClose: Date?
    /// 点击弹窗外部时关闭（status-trio 的全局事件监听做法）。
    private var dismissMonitor: Any?

    init(
        monitor: BatteryMonitor,
        network: NetworkMonitor,
        volume: VolumeMonitor,
        bluetooth: BluetoothMonitor,
        preferences: TrayPreferences
    ) {
        self.monitor = monitor
        self.network = network
        self.volume = volume
        self.bluetooth = bluetooth
        self.preferences = preferences
        super.init()
    }

    deinit {
        appearanceObservation?.invalidate()
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
        }
    }

    // MARK: - 安装

    func install() {
        guard statusItem == nil else { return }

        // macOS 26（Tahoe）由 Control Center 托管菜单栏状态项：
        // 先以零长度创建、同步写入稳定的 autosaveName，再切换到正常宽度，
        // 否则状态项可能「图标可见但点击无响应」。
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = "MacKitStatusItem"
        item.length = NSStatusItem.variableLength
        item.isVisible = true

        guard let button = item.button else { return }

        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshIcon()
            }
        }

        popover.behavior = .transient
        popover.delegate = self

        monitor.objectWillChange
            .merge(with: network.objectWillChange)
            .merge(with: volume.objectWillChange)
            .merge(with: bluetooth.objectWillChange)
            .merge(with: preferences.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshIcon()
                }
            }
            .store(in: &cancellables)

        statusItem = item
        refreshIcon()

        TrayLog.write("install: visible=\(item.isVisible) autosave=\(item.autosaveName ?? "-") size=\(preferences.iconSize)")

        // macOS 26：状态项可能被系统「允许在菜单栏中显示」开关隐藏。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.verifyStatusItemVisibility()
        }
    }

    private func verifyStatusItemVisibility() {
        guard let item = statusItem else { return }
        TrayLog.write("visibility: isVisible=\(item.isVisible) button=\(item.button != nil) window=\(item.button?.window != nil)")

        guard !item.isVisible else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MacKit 的菜单栏图标被系统隐藏了"
        alert.informativeText = "请在「系统设置 › 控制中心 › 菜单栏」中允许 MacKit，然后重新启动应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            _ = NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 图标

    private func updateIcon() {
        let scene = TraySceneMapper.scene(
            battery: monitor.snapshot,
            network: network.snapshot,
            volume: volume.snapshot,
            options: preferences.iconOptions
        )
        guard let button = statusItem?.button else { return }
        button.image = TrayIconRenderer.image(
            scene: scene,
            size: preferences.iconSize,
            appearance: button.effectiveAppearance
        )
        button.toolTip = tooltipText()
    }

    private func refreshIcon() {
        updateIcon()
    }

    private func tooltipText() -> String {
        var parts: [String] = ["MacKit"]
        if let snapshot = monitor.snapshot, snapshot.batteryPresent {
            parts.append("电量 \(snapshot.soc)%")
        }
        switch network.snapshot.connection {
        case .wifi:
            if let ssid = network.snapshot.ssid {
                parts.append("Wi-Fi \(ssid)")
            }
        case .ethernet:
            parts.append("以太网")
        case .none:
            break
        }
        if let scalar = volume.snapshot.scalar {
            let name = volume.snapshot.deviceName ?? "输出"
            parts.append("\(name) \(Int((scalar * 100).rounded()))%")
        }
        if let hardware = monitor.hardware, let cpu = hardware.cpuHotspotC {
            parts.append("CPU \(BatteryFormat.temperature(cpu))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 点击

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        TrayLog.write("click: type=\(event?.type.rawValue ?? 0) ctrl=\(event?.modifierFlags.contains(.control) ?? false)")
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - 弹窗

    private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let lastPopoverClose, Date().timeIntervalSince(lastPopoverClose) < 0.25 {
            return
        }

        ensurePopoverContent()
        network.refreshNow()
        volume.refresh()
        volume.refreshDevices()
        bluetooth.refreshNow()
        // macOS 14+ 推荐使用无参 activate()；两者都调用以兼容新旧系统。
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        TrayLog.write("popover shown=\(popover.isShown)")

        // 与 status-trio 一致：弹窗可以出现在全屏 Space 上，并在外部点击时关闭。
        if let window = popover.contentViewController?.view.window {
            window.enableDisplayOnFullScreenSpaces()
            window.makeKey()
        }
        installDismissMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        removeDismissMonitor()
        TrayLog.write("popover closed")
    }

    private func installDismissMonitor() {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.popover.performClose(nil)
            }
        }
    }

    private func removeDismissMonitor() {
        guard let dismissMonitor else { return }
        NSEvent.removeMonitor(dismissMonitor)
        self.dismissMonitor = nil
    }

    private func ensurePopoverContent() {
        guard popover.contentViewController == nil else { return }
        let rootView = TrayPanelView { [weak self] in
            self?.openMainWindow()
        }
        .environmentObject(monitor)
        .environmentObject(network)
        .environmentObject(volume)
        .environmentObject(bluetooth)
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    // MARK: - 菜单

    private func showMenu() {
        popover.performClose(nil)
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: "打开 MacKit", action: #selector(openMainWindowFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let autoItem = NSMenuItem(title: "自动刷新", action: #selector(toggleAutoRefresh), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = monitor.isPaused ? .off : .on
        menu.addItem(autoItem)

        menu.addItem(.separator())

        volume.refreshDevices()
        let outputItem = NSMenuItem(title: "输出设备", action: nil, keyEquivalent: "")
        outputItem.submenu = makeOutputMenu()
        menu.addItem(outputItem)

        let iconItem = NSMenuItem(title: "托盘图标", action: nil, keyEquivalent: "")
        iconItem.submenu = makeIconMenu()
        menu.addItem(iconItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 MacKit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        TrayLog.write("menu: show")
        guard let button = item.button else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 4),
            in: button
        )
    }

    @objc private func openMainWindowFromMenu() {
        openMainWindow()
    }

    @objc private func refreshFromMenu() {
        monitor.refreshNow()
    }

    @objc private func toggleAutoRefresh() {
        monitor.isPaused.toggle()
    }

    // MARK: - 输出设备

    private func makeOutputMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if volume.outputDevices.isEmpty {
            let empty = NSMenuItem(title: "未找到输出设备", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for device in volume.outputDevices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectOutputDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: Int(device.id))
            item.state = device.isCurrent ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        TrayLog.write("device: select \(number.intValue)")
        volume.selectDevice(AudioDeviceID(number.intValue))
    }

    // MARK: - 托盘图标设置

    private func makeIconMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let percentage = NSMenuItem(
            title: "显示电量百分比",
            action: #selector(toggleShowsPercentage),
            keyEquivalent: ""
        )
        percentage.target = self
        percentage.state = preferences.showsPercentage ? .on : .off
        menu.addItem(percentage)

        let connected = NSMenuItem(
            title: "插电时显示百分比",
            action: #selector(togglePercentageWhenConnected),
            keyEquivalent: ""
        )
        connected.target = self
        connected.state = preferences.showsPercentageWhenConnected ? .on : .off
        menu.addItem(connected)

        let colors = NSMenuItem(
            title: "状态颜色",
            action: #selector(toggleStatusColors),
            keyEquivalent: ""
        )
        colors.target = self
        colors.state = preferences.usesStatusColors ? .on : .off
        menu.addItem(colors)

        menu.addItem(.separator())

        let volumeMenu = NSMenu()
        for (title, style) in [("圆点", TrayVolumeStyle.dots), ("弧线", TrayVolumeStyle.arc)] {
            let styleItem = NSMenuItem(
                title: title,
                action: #selector(selectVolumeStyle(_:)),
                keyEquivalent: ""
            )
            styleItem.target = self
            styleItem.representedObject = style.rawValue
            styleItem.state = preferences.volumeStyle == style ? .on : .off
            volumeMenu.addItem(styleItem)
        }
        let volumeItem = NSMenuItem(title: "音量样式", action: nil, keyEquivalent: "")
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)

        let bluetoothIcon = NSMenuItem(
            title: "蓝牙音频替换网络图标",
            action: #selector(toggleBluetoothAudioIcon),
            keyEquivalent: ""
        )
        bluetoothIcon.target = self
        bluetoothIcon.state = preferences.replacesNetworkIconWithBluetoothAudio ? .on : .off
        menu.addItem(bluetoothIcon)

        let bluetoothColor = NSMenuItem(
            title: "蓝牙音量变蓝",
            action: #selector(toggleBluetoothVolumeColor),
            keyEquivalent: ""
        )
        bluetoothColor.target = self
        bluetoothColor.state = preferences.usesBluetoothVolumeColor ? .on : .off
        menu.addItem(bluetoothColor)

        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (title, value) in [("小", 16.0), ("中", 24.0), ("大", 32.0)] {
            let sizeItem = NSMenuItem(
                title: title,
                action: #selector(selectIconSize(_:)),
                keyEquivalent: ""
            )
            sizeItem.target = self
            sizeItem.representedObject = NSNumber(value: value)
            sizeItem.state = abs(preferences.iconSize - value) < 0.5 ? .on : .off
            sizeMenu.addItem(sizeItem)
        }
        let sizeItem = NSMenuItem(title: "图标大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        return menu
    }

    @objc private func toggleShowsPercentage() {
        preferences.showsPercentage.toggle()
    }

    @objc private func togglePercentageWhenConnected() {
        preferences.showsPercentageWhenConnected.toggle()
    }

    @objc private func toggleStatusColors() {
        preferences.usesStatusColors.toggle()
    }

    @objc private func selectIconSize(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        preferences.iconSize = number.doubleValue
    }

    @objc private func selectVolumeStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = TrayVolumeStyle(rawValue: raw) else { return }
        preferences.volumeStyle = style
    }

    @objc private func toggleBluetoothAudioIcon() {
        preferences.replacesNetworkIconWithBluetoothAudio.toggle()
    }

    @objc private func toggleBluetoothVolumeColor() {
        preferences.usesBluetoothVolumeColor.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 主窗口

    func openMainWindow() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        let normalWindows = NSApp.windows.filter { $0.level == .normal && $0.canBecomeKey }
        if let window = normalWindows.first(where: \.isVisible) ?? normalWindows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }
}

// MARK: - 全屏 Space 支持

private extension NSWindow {
    /// 与 status-trio 的 PopoverWindowPlacement 一致：
    /// `.moveToActiveSpace` 与 `.canJoinAllSpaces` 互斥，必须先移除前者。
    func enableDisplayOnFullScreenSpaces() {
        collectionBehavior.remove(.moveToActiveSpace)
        collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}

// MARK: - 托盘诊断日志

/// 轻量日志，便于排查 macOS 26 菜单栏托管/点击问题：
/// `~/Library/Logs/MacKit/tray.log`。
enum TrayLog {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacKit/tray.log")
    }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

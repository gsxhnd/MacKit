//
//  AppDelegate.swift
//  MacKit
//
//  持有全局监控对象并安装菜单栏状态项。
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = BatteryMonitor()
    let network = NetworkMonitor()
    let volume = VolumeMonitor()
    let bluetooth = BluetoothMonitor()

    private var trayController: TrayStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻应用：禁止系统在主窗口关闭后自动终止进程，
        // 否则托盘图标会随进程一起消失。
        ProcessInfo.processInfo.disableAutomaticTermination("MacKit 常驻菜单栏")
        ProcessInfo.processInfo.disableSuddenTermination()

        // 运行时显式设置 Dock 图标，绕开 LaunchServices 的旧图标缓存。
        let bundledIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:))
        if let icon = NSImage(named: "AppIcon") ?? bundledIcon {
            NSApp.applicationIconImage = icon
        }

        network.start()
        volume.start()
        bluetooth.start()

        let controller = TrayStatusController(
            monitor: monitor,
            network: network,
            volume: volume,
            bluetooth: bluetooth,
            preferences: TrayPreferences()
        )
        controller.install()
        trayController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows
                .first { $0.level == .normal && $0.canBecomeKey && $0.title == "MacKit" }?
                .makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

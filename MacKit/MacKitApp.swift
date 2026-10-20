//
//  MacKitApp.swift
//  MacKit
//
//  Created by gsxhnd on 2026/10/20.
//

import SwiftUI

@main
struct MacKitApp: App {
    @StateObject private var monitor = BatteryMonitor()

    var body: some Scene {
        Window("MacKit", id: "main") {
            AppShellView()
                .environmentObject(monitor)
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新硬件信息") {
                    monitor.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            BatteryMenuView()
                .environmentObject(monitor)
        } label: {
            BatteryMenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.menu)
    }
}

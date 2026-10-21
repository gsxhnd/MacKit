//
//  MacKitApp.swift
//  MacKit
//
//  Created by gsxhnd on 2026/10/20.
//

import SwiftUI

@main
struct MacKitApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("MacKit", id: "main") {
            AppShellView()
                .environmentObject(appDelegate.monitor)
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新硬件信息") {
                    appDelegate.monitor.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

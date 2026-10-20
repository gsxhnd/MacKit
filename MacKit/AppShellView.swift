//
//  AppShellView.swift
//  MacKit
//
//  无标题栏窗口：自定义侧边栏 + 内容区。
//

import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case battery
    case thermal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: "电池"
        case .thermal: "温度与风扇"
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.100"
        case .thermal: "fanblades.fill"
        }
    }
}

struct AppShellView: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @State private var selection: AppSection? = .battery

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            detail
        }
        .frame(minWidth: 1140, minHeight: 700)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChromeConfigurator())
        .overlay(alignment: .top) {
            WindowDragStrip()
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .padding(.leading, 78)
        }
    }

    private var detail: some View {
        Group {
            switch selection ?? .battery {
            case .battery:
                BatteryDashboardView()
            case .thermal:
                ThermalDashboardView()
            }
        }
        .environmentObject(monitor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            brand
                .padding(.horizontal, 16)
                .padding(.top, 36)
                .padding(.bottom, 16)

            VStack(spacing: 4) {
                HStack {
                    Text("监控")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 3)

                ForEach(AppSection.allCases) { section in
                    navigationButton(section)
                }
            }

            Spacer(minLength: 0)

            monitorControls
        }
        .background(.ultraThinMaterial)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.92), .purple.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "leaf.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .shadow(color: .purple.opacity(0.18), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacKit")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("硬件监控")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func navigationButton(_ section: AppSection) -> some View {
        let isSelected = selection == section
        let rowTint = tint(for: section)

        return Button {
            withAnimation(.smooth(duration: 0.18)) {
                selection = section
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.24) : rowTint.opacity(0.14))
                    Image(systemName: section.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(isSelected ? Color.white : rowTint)
                }
                .frame(width: 21, height: 21)

                Text(section.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                Spacer(minLength: 6)

                Text(value(for: section))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private var monitorControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.5)

            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isPaused ? Color.secondary : Color.green)
                    .frame(width: 6, height: 6)
                Text(monitor.isPaused ? "监控已暂停" : "实时监控")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(monitor.refreshRate.rawValue)s")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Picker("刷新间隔", selection: $monitor.refreshRate) {
                    ForEach(BatteryMonitor.RefreshRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                Button {
                    monitor.isPaused.toggle()
                } label: {
                    Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(monitor.isPaused ? "恢复自动刷新" : "暂停自动刷新")

                Button {
                    monitor.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help("立即刷新")
                .disabled(monitor.isRefreshing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func tint(for section: AppSection) -> Color {
        switch section {
        case .battery: monitor.snapshot?.state.tint ?? .green
        case .thermal: .orange
        }
    }

    private func value(for section: AppSection) -> String {
        switch section {
        case .battery:
            monitor.snapshot.map { "\($0.soc)%" } ?? "—"
        case .thermal:
            monitor.hardware?.cpuHotspotC.map { String(format: "%.0f°", $0) } ?? "—"
        }
    }
}

// MARK: - 无标题栏窗口配置

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true

            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        private var resizeObserver: NSObjectProtocol?

        func attach(to window: NSWindow) {
            clean(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak window] in
                guard let window else { return }
                self.clean(window)
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                self.clean(window)
            }
        }

        private func clean(_ window: NSWindow) {
            guard let content = window.contentView else { return }
            removeScrollPockets(in: content)
        }

        private func removeScrollPockets(in view: NSView) {
            let name = String(describing: type(of: view))

            if name.contains("HostingScrollView") {
                if let scrollView = view as? NSScrollView {
                    scrollView.automaticallyAdjustsContentInsets = false
                    scrollView.contentInsets = NSEdgeInsets()
                    scrollView.scrollerInsets = NSEdgeInsets()
                }
                for subview in view.subviews {
                    let subName = String(describing: type(of: subview))
                    if subName == "BackdropView" || subName == "NSScrollPocket" || subName.contains("ScrollPocket") {
                        subview.isHidden = true
                    }
                }
            }

            for subview in view.subviews {
                removeScrollPockets(in: subview)
            }
        }
    }
}

private struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

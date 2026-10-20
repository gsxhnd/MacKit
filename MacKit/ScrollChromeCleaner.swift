import AppKit
import SwiftUI

/// Hides the macOS 26 scroll pocket / edge backdrop that SwiftUI creates for
/// the titlebar safe area. Without this, a white strip can appear at the top
/// of the content in a hidden-titlebar window.
struct ScrollChromeCleaner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        scheduleCleanup(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleCleanup(for: nsView)
    }

    private func scheduleCleanup(for view: NSView) {
        for delay in [0.05, 0.25, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view else { return }
                clean(view)
            }
        }
    }

    private func clean(_ view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.scrollerInsets = NSEdgeInsets()

        for subview in scrollView.subviews {
            let name = String(describing: type(of: subview))
            if name == "BackdropView" || name == "NSScrollPocket" || name.contains("ScrollPocket") {
                subview.isHidden = true
            }
        }
    }
}

import AppKit
import SwiftUI
import SwitchBarCore

/// Ventana de consumo, gestionada con AppKit por lo mismo que la de detalle:
/// en una app sin Dock es la única forma fiable de abrirla y traerla al frente.
@MainActor
final class UsageWindowController: NSObject, NSWindowDelegate {
    static let shared = UsageWindowController()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: TokenUsageView(model: TokenUsageModel.shared, state: AppState.shared)
            )
            let w = NSWindow(contentViewController: hosting)
            w.title = L10n.tr("usage_stats.window_title")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.setContentSize(NSSize(width: 900, height: 820))
            w.contentMinSize = NSSize(width: 760, height: 560)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("SwitchBarUsageWindow")
            w.delegate = self
            window = w
            if !w.setFrameUsingName("SwitchBarUsageWindow") { w.center() }
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        TokenUsageModel.shared.windowVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        TokenUsageModel.shared.windowVisible = false
        AppActivation.windowWillClose()
    }
}

/// La app aparece en el Dock mientras tenga alguna ventana abierta; al cerrar
/// la última vuelve a vivir solo en la barra de menús.
@MainActor
enum AppActivation {
    static func windowWillClose() {
        // El aviso llega antes de que la ventana se oculte: se comprueba en
        // la siguiente vuelta del bucle.
        DispatchQueue.main.async {
            if !DetailWindowController.shared.isVisible && !UsageWindowController.shared.isVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

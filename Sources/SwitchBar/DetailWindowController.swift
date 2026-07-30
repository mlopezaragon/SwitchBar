import AppKit
import SwiftUI

/// Ventana de detalle gestionada con AppKit. En una app sin Dock, la apertura
/// vía `openWindow` depende del ciclo de vida de las escenas de SwiftUI y no
/// siempre llega a ejecutarse; con NSWindow el resultado es determinista.
///
/// Mientras la ventana está abierta, la app pasa a política `.regular`: sin
/// eso, macOS no la trae al frente (una app accesoria no puede activarse) y la
/// ventana quedaría detrás de todo. Al cerrarla vuelve a `.accessory` para
/// desaparecer del Dock y del conmutador de apps.
@MainActor
final class DetailWindowController: NSObject, NSWindowDelegate {
    static let shared = DetailWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: DetailView(state: AppState.shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "SwitchBar"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.setContentSize(NSSize(width: 680, height: 620))
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        centerOnActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `NSWindow.center()` puede dejar la ventana en otra pantalla (con
    /// monitores apilados acaba fuera de la vista), así que se centra a mano
    /// sobre la pantalla que tiene el ratón, o la principal.
    private func centerOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

import Sparkle
import SwiftUI

/// Actualizador Sparkle compartido. Comprueba en segundo plano contra el
/// appcast firmado (EdDSA) publicado en el repositorio; el usuario también
/// puede comprobar a mano desde la ventana de detalle.
@MainActor
enum AppUpdater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Delegado: la ventana de detalle se abre al arrancar sin cuentas guardadas y
/// cada vez que se reabre la app (doble clic en /Aplicaciones, Spotlight). Sin
/// esto, al no tener Dock, no habría señal visible si el icono de la barra de
/// menús queda oculto por falta de espacio.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestPermission()
        // Arranca el actualizador ya: las comprobaciones automáticas de
        // Sparkle solo se programan si el controlador existe desde el inicio.
        _ = AppUpdater.controller
        if AppState.shared.profilesList.isEmpty {
            DetailWindowController.shared.show()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.refreshAfterResume()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DetailWindowController.shared.show()
        AppState.shared.refreshAfterResume()
        return true
    }
}

@main
struct SwitchBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(state: state)
        } label: {
            Image(nsImage: MenuBarIconRenderer.image(fraction: state.activeFiveHourFraction))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Icono de la barra: anillo con el uso de 5 h de la cuenta activa, renderizado
/// como imagen de plantilla (las vistas con formas no siempre se dibujan en la
/// barra de menús; una NSImage template funciona siempre y se adapta al tema).
enum MenuBarIconRenderer {
    static func image(fraction: Double?) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let center = NSPoint(x: side / 2, y: side / 2)
            let radius: CGFloat = 6.2
            let lineWidth: CGFloat = 1.9

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()

            if let fraction {
                let sweep = 360 * min(max(fraction, 0.03), 1)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }

            let dotRadius: CGFloat = 1.6
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                                  width: dotRadius * 2, height: dotRadius * 2))
            NSColor.black.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

import AppKit
import SwiftUI

/// Where the installer window opens. SwiftUI centres it on its first, shortest
/// page, and later pages grow it downwards from its top edge, so a centred
/// window ends up hanging low. It opens instead where its tallest page would be
/// centred, so no page ever sits below the middle of the screen.
enum InstallerWindowPlacement {
  /// The window's frame raised or lowered to that spot, in AppKit's screen
  /// coordinates; `growth` is how much taller the tallest page makes it.
  static func frame(_ frame: CGRect, growth: CGFloat, visible: CGRect) -> CGRect {
    let gap = max((visible.height - frame.height - max(growth, 0)) / 2, 0)
    var placed = frame
    placed.origin.y = (visible.maxY - gap - frame.height).rounded(.down)
    return placed
  }
}

/// Moves its window once, after SwiftUI has placed it and before it is shown.
/// SwiftUI's own `defaultWindowPlacement` put the window at the bottom of a
/// display arranged above the built-in one, so this works in AppKit's terms.
struct InstallerWindowPlacer: NSViewRepresentable {
  let growth: CGFloat

  func makeNSView(context: Context) -> PlacerView {
    let view = PlacerView()
    view.growth = growth
    return view
  }

  func updateNSView(_ view: PlacerView, context: Context) {
    view.growth = growth
  }

  final class PlacerView: NSView {
    var growth: CGFloat = 0
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard let window, !window.isVisible else { return }
      // The first update comes after SwiftUI centres the window, before it is
      // ordered on screen, so the move never shows.
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.place() }
      }
    }

    private func place() {
      stopObserving()
      guard let window, !window.isVisible, let screen = window.screen ?? NSScreen.main else {
        return
      }
      window.setFrame(
        InstallerWindowPlacement.frame(
          window.frame, growth: growth, visible: screen.visibleFrame),
        display: false)
    }

    private func stopObserving() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
    }
  }
}

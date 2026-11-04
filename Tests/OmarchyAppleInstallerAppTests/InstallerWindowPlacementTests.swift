#if os(macOS)
  import XCTest
  @testable import OmarchyAppleInstallerApp

  final class InstallerWindowPlacementTests: XCTestCase {
    /// A 14-inch MacBook Pro's visible area below the menu bar, and the window
    /// as SwiftUI centres it on the 400 point first page (432 with its title
    /// bar), measured with the installer's scene settings.
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let centred = CGRect(x: 366, y: 258, width: 780, height: 432)
    let growth: CGFloat = 680 - 400

    func testTheFirstPageOpensWhereTheTallestPageIsCentred() {
      let placed = InstallerWindowPlacement.frame(centred, growth: growth, visible: builtIn)
      XCTAssertEqual(placed.minX, centred.minX)
      XCTAssertEqual(placed.size, centred.size)
      let above = builtIn.maxY - placed.maxY
      XCTAssertEqual(above, 119)
      // Grown downwards to the tallest page, top edge in place: centred.
      XCTAssertEqual(placed.minY - growth - builtIn.minY, 118)
    }

    func testNoPageSitsBelowTheMiddle() {
      for height in stride(from: 760, through: 2200, by: 40) {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: CGFloat(height))
        let placed = InstallerWindowPlacement.frame(centred, growth: growth, visible: visible)
        for page in stride(from: CGFloat(0), through: growth, by: 20) {
          let bottom = placed.minY - page
          XCTAssertGreaterThanOrEqual(
            (placed.maxY + bottom) / 2, visible.midY - 1, "\(height) +\(page)")
        }
      }
    }

    func testADisplayAboveTheBuiltInOneUsesItsOwnFrame() {
      // An external display arranged above a 982 point tall built-in screen.
      let external = CGRect(x: -806, y: 982, width: 3008, height: 1662)
      let window = CGRect(x: 308, y: 1597, width: 780, height: 432)
      let placed = InstallerWindowPlacement.frame(window, growth: growth, visible: external)
      XCTAssertEqual(external.maxY - placed.maxY, 475)
      XCTAssertEqual(placed.minY - growth - external.minY, 475)
    }

    func testAScreenShorterThanTheTallestPageOpensAtTheTop() {
      let short = CGRect(x: 0, y: 0, width: 1280, height: 640)
      let placed = InstallerWindowPlacement.frame(centred, growth: growth, visible: short)
      XCTAssertEqual(placed.maxY, short.maxY)
    }
  }
#endif

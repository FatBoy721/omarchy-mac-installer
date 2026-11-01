#if os(macOS)
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class DiskutilInstallConfFATTests: XCTestCase {
    func testExistingFATMountUsesTheRealVerifier() throws {
      let volume = try FATMountFixture()
      defer { XCTAssertNoThrow(try volume.remove()) }
      let disks = DiskutilInstallConfESPOperator()
      let descriptor = try disks.mount(volume.identifier, at: volume.destination)
      Darwin.close(descriptor)
    }

    func testFreshPrivateFATMountAndRemountUseTheRealVerifier() throws {
      let volume = try FATMountFixture()
      defer { XCTAssertNoThrow(try volume.remove()) }
      let disks = DiskutilInstallConfESPOperator()
      try disks.unmount(volume.identifier)
      for _ in 0..<2 {
        let descriptor = try disks.mount(volume.identifier, at: volume.destination)
        Darwin.close(descriptor)
        try disks.unmount(volume.identifier)
      }
    }
  }

  /// Only the disk image created here is attached, mounted or detached.
  private struct FATMountFixture {
    let root: URL
    let identifier: String
    let destination: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "esp-fat-\(UUID().uuidString)", isDirectory: true)
      destination = root.appendingPathComponent("private-mount", isDirectory: true)
      let existing = root.appendingPathComponent("existing", isDirectory: true)
      try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let image = root.appendingPathComponent("esp.dmg")
      var attached = false
      do {
        _ = try Self.run(
          "/usr/bin/hdiutil",
          [
            "create", "-size", "64m", "-fs", "MS-DOS", "-fsargs", "-F 32", "-volname",
            "EFI - OMARC",
            "-layout", "NONE", image.path,
          ])
        let data = try Self.run(
          "/usr/bin/hdiutil",
          [
            "attach", "-plist", "-nobrowse", "-mountpoint", existing.path, image.path,
          ])
        attached = true
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let listing = plist as? [String: Any],
          let entities = listing["system-entities"] as? [[String: Any]],
          let mounted = entities.first(where: { $0["mount-point"] is String }),
          let device = mounted["dev-entry"] as? String,
          device.range(of: #"^/dev/disk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil
        else { throw InstallConfESPError.mountFailed }
        identifier = String(device.dropFirst("/dev/".count))
      } catch {
        if !attached || (try? Self.run("/usr/bin/hdiutil", ["detach", existing.path])) != nil {
          try? FileManager.default.removeItem(at: root)
        }
        throw error
      }
    }

    func remove() throws {
      _ = try Self.run("/usr/bin/hdiutil", ["detach", "/dev/\(identifier)"])
      try FileManager.default.removeItem(at: root)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      process.standardInput = FileHandle.nullDevice
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw NSError(
          domain: executable, code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
      }
      return output
    }
  }
#endif

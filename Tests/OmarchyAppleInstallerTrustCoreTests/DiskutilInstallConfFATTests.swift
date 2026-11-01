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

    func testRealFATWriterReplacesTheChoiceAndPersistsAcrossReattachment() throws {
      let volume = try FATMountFixture()
      defer { XCTAssertNoThrow(try volume.remove()) }
      let disks = FATWriterDisks(identifier: volume.identifier)
      let writer = InstallConfESPMountWriter(
        disks: disks, workingDirectory: volume.root.appendingPathComponent("handoff"))
      let enabled = try InstallConf(encrypt: true, lane: "stable")
      try writer.write(
        enabled, storeIdentifier: disks.storeIdentifier, offsetBytes: 50, lengthBytes: 200)

      // Reuse the image's existing mount again, with an install.conf to replace.
      let descriptor = try disks.mount(volume.identifier, at: volume.existingMountPoint)
      Darwin.close(descriptor)
      let disabled = try InstallConf(encrypt: false, lane: "edge")
      try writer.write(
        disabled, storeIdentifier: disks.storeIdentifier, offsetBytes: 50, lengthBytes: 200)

      try volume.reattach()
      let directory = volume.existingMountPoint.appendingPathComponent(InstallConf.directoryName)
      XCTAssertEqual(
        try Data(contentsOf: directory.appendingPathComponent(InstallConf.fileName)),
        disabled.serializedData)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: directory.path), [InstallConf.fileName])
    }
  }

  /// Only the locator's plan metadata is stubbed; mounts and writes are real.
  private struct FATWriterDisks: InstallConfESPDiskOperating {
    let identifier: String
    private let disks = DiskutilInstallConfESPOperator()
    var storeIdentifier: String {
      identifier.replacingOccurrences(of: #"s[0-9]+$"#, with: "", options: .regularExpression)
    }

    func partitions(on storeIdentifier: String) throws -> [InstallConfESPPartition] {
      [
        .init(
          identifier: identifier, storeIdentifier: storeIdentifier, type: "EFI",
          name: "EFI - OMARC", offsetBytes: 100, lengthBytes: 50)
      ]
    }

    func mount(_ identifier: String, at mountPoint: URL) throws -> Int32 {
      try disks.mount(identifier, at: mountPoint)
    }

    func unmount(_ identifier: String) throws { try disks.unmount(identifier) }
  }

  /// Only the disk image created here is attached, mounted or detached.
  private final class FATMountFixture {
    let root: URL
    let destination: URL
    private(set) var identifier = ""
    private var attached = false
    var existingMountPoint: URL { root.appendingPathComponent("existing", isDirectory: true) }
    private var image: URL { root.appendingPathComponent("esp.dmg") }

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "esp-fat-\(UUID().uuidString)", isDirectory: true)
      destination = root.appendingPathComponent("private-mount", isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      do {
        _ = try Self.run(
          "/usr/bin/hdiutil",
          [
            "create", "-size", "256m", "-fs", "MS-DOS", "-fsargs", "-F 32", "-volname",
            "EFI - OMARC",
            "-layout", "GPTSPUD", image.path,
          ])
        try attach()
      } catch {
        if !attached || (try? detach()) != nil {
          try? FileManager.default.removeItem(at: root)
        }
        throw error
      }
    }

    private func attach() throws {
      try FileManager.default.createDirectory(
        at: existingMountPoint, withIntermediateDirectories: true)
      let data = try Self.run(
        "/usr/bin/hdiutil",
        [
          "attach", "-plist", "-nobrowse", "-mountpoint", existingMountPoint.path, image.path,
        ])
      attached = true
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
      guard let listing = plist as? [String: Any],
        let entities = listing["system-entities"] as? [[String: Any]],
        let mounted = entities.first(where: { $0["mount-point"] is String }),
        let device = mounted["dev-entry"] as? String,
        device.range(of: #"^/dev/disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
      else { throw InstallConfESPError.mountFailed }
      identifier = String(device.dropFirst("/dev/".count))
    }

    func remove() throws {
      try detach()
      try FileManager.default.removeItem(at: root)
    }

    func reattach() throws {
      try detach()
      try attach()
    }

    private func detach() throws {
      guard attached else { return }
      guard !identifier.isEmpty else { throw InstallConfESPError.notFound }
      for attempt in 0..<3 {
        do {
          _ = try Self.run("/usr/bin/hdiutil", ["detach", "/dev/\(identifier)"])
          attached = false
          identifier = ""
          return
        } catch {
          if attempt == 2 { throw error }
          Thread.sleep(forTimeInterval: 0.2)
        }
      }
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

#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  /// An install that stopped inside stub_and_esp, before asahi/ on its ESP
  /// was written, is proven by the helper's own install journal instead.
  final class OmarchyRemovalInterruptedInstallTests: XCTestCase {
    typealias F = RemovalFixtures

    static let planDigest = "sha256:" + String(repeating: "ab", count: 32)

    struct Journal {
      var planOffset: UInt64
      var planLength: UInt64
      var stub: RemovalPartition
      var events = ["apfs_preparation_started", "stub_and_esp_started"]
      var checkpoints = ["apfs-target-prepared"]
      var completion = false
      var stubUUID: String? = nil
      var stubOffset: UInt64? = nil

      var target: Data {
        let object: [String: Any] = [
          "plan_digest": OmarchyRemovalInterruptedInstallTests.planDigest,
          "partition_identifier": stub.identifier,
          "offset_bytes": stubOffset ?? stub.offset,
          "size_bytes": stub.size,
          "uuid": (stubUUID ?? stub.uuid).lowercased(),
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      }

      var transcript: Data {
        let digest = OmarchyRemovalInterruptedInstallTests.planDigest
        var records: [(String, [String: Any])] = [
          ("inspection", ["device_identifier": "disk0"]),
          ("inventory", ["layout_digest": digest]),
          ("plan", ["plan_digest": digest, "offset_bytes": planOffset, "length_bytes": planLength]),
        ]
        records += events.map { ("event", ["plan_digest": digest, "name": $0]) }
        records += checkpoints.map {
          (
            "checkpoint",
            [
              "plan_digest": digest, "identifier": $0, "phase": "apfs_preparation",
              "evidence_digest": $0 == "apfs-target-prepared"
                ? SHA256Digest(hashing: target).rawValue
                : "sha256:" + String(repeating: "cd", count: 32),
            ]
          )
        }
        if completion {
          records.append(("completion", ["plan_digest": digest, "outcome": "awaiting_recovery"]))
        }
        var data = Data()
        for (index, record) in records.enumerated() {
          let line: [String: Any] = [
            "schema_version": 1, "sequence": index + 1, "type": record.0, "payload": record.1,
          ]
          data.append(try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
          data.append(10)
        }
        return data
      }

      var parsed: RemovalInterruptedInstall? {
        RemovalInterruptedInstall.parse(transcript: transcript, target: target)
      }
    }

    /// The M2 lab layout, with the journal of the plan that made it.
    func journal(_ snapshot: RemovalSnapshot = F.converged()) -> Journal {
      let members = [F.convergedInstall.stub, F.convergedInstall.esp] + F.convergedInstall.linux
      let parts = members.map { uuid in snapshot.partitions.first { $0.uuid == uuid }! }
      return Journal(
        planOffset: parts[0].offset, planLength: parts[3].end - parts[0].offset, stub: parts[0])
    }

    /// What a Mac stranded by the Recovery staging failure has: no asahi/ records.
    func strandedDisk(_ records: [RemovalInterruptedInstall]) -> FakeRemovalDisk {
      let disk = FakeRemovalDisk()
      disk.files?.stubInfo = nil
      disk.files?.installerLog = nil
      disk.files?.interruptedInstalls = records
      return disk
    }

    let refusal =
      "Found the installation “Omarchy” (disk0s3, disk0s4, disk0s5, disk0s6), but %@. It can’t be confirmed as one installation, so nothing was changed."

    func assertRefusal(
      _ disk: FakeRemovalDisk, _ reason: String, file: StaticString = #filePath, line: UInt = #line
    ) {
      XCTAssertThrowsError(try OmarchyRemovalPlan(disks: disk), file: file, line: line) { error in
        XCTAssertEqual(
          (error as? RemovalFailure)?.message, String(format: refusal, reason), file: file,
          line: line)
      }
      XCTAssertTrue(disk.operations.isEmpty, file: file, line: line)
    }

    // MARK: Parsing

    func testJournalOfTheStoppedInstallParses() throws {
      let journal = journal()
      let record = try XCTUnwrap(journal.parsed)
      XCTAssertEqual(record.stubUUID, F.convergedInstall.stub)
      XCTAssertEqual(record.stubOffset, journal.stub.offset)
      XCTAssertEqual(record.stubSize, journal.stub.size)
      XCTAssertEqual(record.planOffset, journal.planOffset)
      XCTAssertEqual(record.planLength, journal.planLength)
      XCTAssertEqual(record.journal, SHA256Digest(hashing: journal.transcript))
    }

    func testOnlyAnInstallThatStoppedInStubAndESPParses() {
      var finished = journal()
      finished.checkpoints.append("stub-and-esp-installed")
      XCTAssertNil(finished.parsed)

      var completed = journal()
      completed.completion = true
      XCTAssertNil(completed.parsed)

      var notStarted = journal()
      notStarted.events.removeLast()
      XCTAssertNil(notStarted.parsed)

      var noTarget = journal()
      noTarget.checkpoints = []
      XCTAssertNil(noTarget.parsed)

      var replaced = journal()
      replaced.checkpoints.insert("existing-install-removed", at: 0)
      XCTAssertNotNil(replaced.parsed)
    }

    func testTamperedOrMalformedJournalsProveNothing() {
      let journal = journal()
      // Evidence that isn't the checkpoint's.
      var target = journal.target
      target.append(32)
      XCTAssertNil(RemovalInterruptedInstall.parse(transcript: journal.transcript, target: target))
      // A torn last record.
      XCTAssertNil(
        RemovalInterruptedInstall.parse(
          transcript: journal.transcript.dropLast(), target: journal.target))
      // Records out of sequence.
      var lines = String(decoding: journal.transcript, as: UTF8.self)
        .split(separator: "\n").map(String.init)
      lines.swapAt(3, 4)
      let shuffled = Data((lines.joined(separator: "\n") + "\n").utf8)
      XCTAssertNil(RemovalInterruptedInstall.parse(transcript: shuffled, target: journal.target))
      // A stub that doesn't start the approved extent.
      var moved = journal
      moved.stubOffset = journal.stub.offset + 4096
      XCTAssertNil(moved.parsed)
      // A boolean where a size belongs.
      let boolean = String(decoding: journal.transcript, as: UTF8.self)
        .replacingOccurrences(of: "\"length_bytes\":\(journal.planLength)", with: "\"length_bytes\":true")
      XCTAssertNil(
        RemovalInterruptedInstall.parse(transcript: Data(boolean.utf8), target: journal.target))
    }

    // MARK: Recognition

    func testStrandedInstallIsRemovableOnTheJournalsProof() throws {
      let disk = strandedDisk([try XCTUnwrap(journal().parsed)])
      let plan = try OmarchyRemovalPlan(disks: disk)
      XCTAssertEqual(plan.kind, .installation)
      XCTAssertEqual(
        plan.members.map(\.uuid),
        [F.convergedInstall.stub, F.convergedInstall.esp] + F.convergedInstall.linux)
      try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in }
      XCTAssertFalse(disk.operations.isEmpty)
    }

    func testWithoutAJournalTheStrandedInstallIsStillRefused() {
      assertRefusal(strandedDisk([]), "its EFI partition has no readable asahi/stub_info.json")
    }

    func testTheJournalNeverOverridesARecordOnTheESP() throws {
      // One record present: the strict checks of that record apply, as before.
      let disk = strandedDisk([try XCTUnwrap(journal().parsed)])
      disk.files?.installerLog = RemovalFixtures.files(
        for: F.convergedInstall, in: F.converged()
      ).installerLog
      assertRefusal(disk, "its EFI partition has no readable asahi/stub_info.json")
    }

    func testJournalThatDoesNotMatchTheDiskIsRefused() throws {
      let mismatch =
        "the installer’s record of the installation that stopped doesn’t match the disk"
      // The plan's extent ends before the Root partition does.
      var short = journal()
      short.planLength -= 1
      assertRefusal(strandedDisk([try XCTUnwrap(short.parsed)]), mismatch)

      // A startup container of another size at that place.
      var resized = journal()
      resized.stub.size -= 4096
      assertRefusal(strandedDisk([try XCTUnwrap(resized.parsed)]), mismatch)

      // A journal for another startup container proves nothing about this one.
      var other = journal()
      other.stubUUID = F.id(901)
      assertRefusal(
        strandedDisk([try XCTUnwrap(other.parsed)]),
        "its EFI partition has no readable asahi/stub_info.json")

      // Two journals naming this container are ambiguous.
      let record = try XCTUnwrap(journal().parsed)
      var second = journal()
      second.events.insert("existing_removal_started", at: 0)
      assertRefusal(
        strandedDisk([record, try XCTUnwrap(second.parsed)]),
        "its EFI partition has no readable asahi/stub_info.json")
    }

    func testTheStartupContainerChecksStillApply() throws {
      let disk = strandedDisk([try XCTUnwrap(journal().parsed)])
      disk.files?.stubBootObject = Data(
        "##m1n1_ver##1\0STACKBOTchosen.asahi,efi-system-partition=\(F.id(77).lowercased())\n\0"
          .utf8)
      assertRefusal(
        disk, "the m1n1 boot object in its startup container doesn’t point to this EFI partition")
    }

    func testRemovalRecordsSavedBeforeThisFieldStillDecode() throws {
      let evidence = RemovalEvidence(
        files: RemovalFixtures.files(for: F.convergedInstall, in: F.converged()))
      var object =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as! [String: Any]
      XCTAssertNil(object["interruptedInstalls"])
      object.removeValue(forKey: "interruptedInstalls")
      let decoded = try JSONDecoder().decode(
        RemovalEvidence.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertEqual(decoded, evidence)
    }
  }
#endif

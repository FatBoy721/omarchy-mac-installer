#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  /// An install that stopped inside stub_and_esp, before asahi/ on its ESP
  /// was written, is proven by the helper's own install journal instead.
  final class OmarchyRemovalInterruptedInstallTests: XCTestCase {
    typealias F = RemovalFixtures

    static let planDigest = String(repeating: "ab", count: 32)

    /// The M2 lab Mac's install journal of 2026-11-05 as it stood when
    /// stub_and_esp began, and its apfs-target-prepared evidence, verbatim.
    static let m2Journal = #"""
      {"payload":{"device_identifier":"apple,j416c","support":"supported"},"schema_version":1,"sequence":1,"type":"inspection"}
      {"payload":{"candidates":[{"kind":"resize","length_bytes":994662584320,"minimum_container_bytes":320952336384,"minimum_install_bytes":39531315200,"offset_bytes":524312576,"recommended_container_bytes":320952336384,"recommended_install_bytes":76562825216,"source_identifier":"disk0s2"}],"layout_digest":"sha256:45772bb3571562eea859a31406a494f4e1dcfc85928097af5e78e880ce94f7f0","system_store_identifier":"disk0"},"schema_version":1,"sequence":2,"type":"inventory"}
      {"payload":{"candidate_kind":"resize","device_identifier":"apple,j416c","engine_digest":"sha256:5fea6b561e6fb82260f573bae099c70ba2e9998df56d38cf285987432320d4b5","engine_version":"v0.9.2-omarchy.20261022.31425f17fb9b","layout_digest":"sha256:45772bb3571562eea859a31406a494f4e1dcfc85928097af5e78e880ce94f7f0","length_bytes":367999844352,"metadata_digest":"sha256:99b730daee51eb1acb385be0b73fe25c51b3aa1e7d33e7be6e13a66c25122f42","offset_bytes":627187052544,"payload_digest":"sha256:ad6f83c99488688dcbb7b00935a018256aeb24240d6b9a40d9efa0ffc72316ad","plan_digest":"b68fa22f843b757b3052525bebc28ec7daf7609689e7da651febed590e959cb8","required_human_steps":["enterOneTrueRecovery","authenticateMachineOwner"],"source_identifier":"disk0s2","store_identifier":"disk0"},"schema_version":1,"sequence":3,"type":"plan"}
      {"payload":{"name":"apfs_preparation_started","plan_digest":"b68fa22f843b757b3052525bebc28ec7daf7609689e7da651febed590e959cb8"},"schema_version":1,"sequence":4,"type":"event"}
      {"payload":{"evidence_digest":"sha256:82b7cabca5d6eab8ba059c05472601cbf4b0b1f906c70de7f133f55e84fdc2f6","identifier":"apfs-target-prepared","phase":"apfs_preparation","plan_digest":"b68fa22f843b757b3052525bebc28ec7daf7609689e7da651febed590e959cb8"},"schema_version":1,"sequence":5,"type":"checkpoint"}
      {"payload":{"name":"stub_and_esp_started","plan_digest":"b68fa22f843b757b3052525bebc28ec7daf7609689e7da651febed590e959cb8"},"schema_version":1,"sequence":6,"type":"event"}

      """#
    static let m2Target = Data(
      #"{"offset_bytes":627187052544,"partition_identifier":"disk0s3","plan_digest":"b68fa22f843b757b3052525bebc28ec7daf7609689e7da651febed590e959cb8","size_bytes":2499805184,"uuid":"D8E7A578-1EAA-4D33-B70B-186780564762"}"#
        .utf8)

    static let legacyEngine = "v0.9.2-omarchy.20261022.31425f17fb9b"
    static let receiptEngine = "v0.9.2-omarchy.20261106.2a7496426118"

    struct Journal {
      var planOffset: UInt64
      var planLength: UInt64
      var stub: RemovalPartition
      var events = ["apfs_preparation_started", "stub_and_esp_started"]
      var checkpoints = ["apfs-target-prepared"]
      var completion = false
      var stubUUID: String? = nil
      var stubOffset: UInt64? = nil
      var engine = OmarchyRemovalInterruptedInstallTests.legacyEngine
      /// The partitions a receipt names; nil writes no receipt.
      var recorded: [RemovalPartition]? = nil

      var receipt: Data? {
        recorded.map { parts in
          let object: [String: Any] = [
            "plan_digest": OmarchyRemovalInterruptedInstallTests.planDigest,
            "partitions": parts.map {
              ["uuid": $0.uuid, "offset_bytes": $0.offset, "size_bytes": $0.size] as [String: Any]
            },
          ]
          return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
      }

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
          (
            "plan",
            [
              "plan_digest": digest, "offset_bytes": planOffset, "length_bytes": planLength,
              "engine_version": engine,
            ]
          ),
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
        RemovalInterruptedInstall.parse(transcript: transcript, target: target, receipt: receipt)
      }
    }

    static var members: [RemovalPartition] {
      let snapshot = F.converged()
      return ([F.convergedInstall.stub, F.convergedInstall.esp] + F.convergedInstall.linux).map {
        uuid in snapshot.partitions.first { $0.uuid == uuid }!
      }
    }

    /// The M2 lab layout, with the journal of the plan that made it.
    func journal() -> Journal {
      let parts = Self.members
      return Journal(
        planOffset: parts[0].offset, planLength: parts[3].end - parts[0].offset, stub: parts[0])
    }

    /// The same, from an engine that recorded every partition it created.
    func receiptJournal() -> Journal {
      var journal = journal()
      journal.engine = Self.receiptEngine
      journal.recorded = Self.members
      return journal
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

    func testARealEngineJournalParses() throws {
      let record = try XCTUnwrap(
        RemovalInterruptedInstall.parse(
          transcript: Data(Self.m2Journal.utf8), target: Self.m2Target))
      XCTAssertEqual(record.stubUUID, "D8E7A578-1EAA-4D33-B70B-186780564762")
      XCTAssertEqual(record.stubOffset, 627_187_052_544)
      XCTAssertEqual(record.stubSize, 2_499_805_184)
      XCTAssertEqual(record.planOffset, 627_187_052_544)
      XCTAssertEqual(record.planLength, 367_999_844_352)
      // A "sha256:"-prefixed plan digest is not what the engine writes.
      let prefixed = Self.m2Journal.replacingOccurrences(
        of: #""plan_digest":"b68f"#, with: #""plan_digest":"sha256:b68f"#)
      XCTAssertNil(
        RemovalInterruptedInstall.parse(transcript: Data(prefixed.utf8), target: Self.m2Target))
    }

    func testEvidenceDoesNotDependOnTheOrderJournalsAreListed() throws {
      let first = try XCTUnwrap(journal().parsed)
      var other = journal()
      other.stubUUID = F.id(901)
      let second = try XCTUnwrap(other.parsed)
      var files = RemovalFixtures.files(for: F.convergedInstall, in: F.converged())
      files.interruptedInstalls = [first, second]
      let listed = RemovalEvidence(files: files)
      files.interruptedInstalls = [second, first]
      XCTAssertEqual(RemovalEvidence(files: files), listed)
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
        .replacingOccurrences(
          of: "\"length_bytes\":\(journal.planLength)", with: "\"length_bytes\":true")
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
      disk.files?.installerLog =
        RemovalFixtures.files(
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

    // MARK: Partition receipts

    func testAReceiptProvesEveryPartitionEvenBeforeTheESPWasWritten() throws {
      // The payload download failed: nothing on the ESP, no m1n1 in the stub.
      let disk = strandedDisk([try XCTUnwrap(receiptJournal().parsed)])
      disk.files?.espBootObject = nil
      disk.files?.stubBootObject = nil
      let plan = try OmarchyRemovalPlan(disks: disk)
      XCTAssertEqual(plan.members.map(\.uuid), Self.members.map(\.uuid))
      XCTAssertTrue(
        plan.ticket(id: UUID()).notes.contains {
          $0.hasPrefix("An earlier install stopped partway")
        })
      try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in }
      XCTAssertFalse(disk.operations.isEmpty)
    }

    func testAReceiptCoversEitherMissingRecord() throws {
      let disk = strandedDisk([try XCTUnwrap(receiptJournal().parsed)])
      disk.files?.stubInfo =
        RemovalFixtures.files(for: F.convergedInstall, in: F.converged())
        .stubInfo
      XCTAssertNoThrow(try OmarchyRemovalPlan(disks: disk))
    }

    func testAReceiptMustNameEveryPartitionExactly() throws {
      var swapped = receiptJournal()
      let root = swapped.recorded![3]
      swapped.recorded![3] = RemovalPartition(
        identifier: root.identifier, uuid: F.id(902), type: root.type, offset: root.offset,
        size: root.size, name: root.name)
      assertRefusal(
        strandedDisk([try XCTUnwrap(swapped.parsed)]),
        "the installer’s record of the installation that stopped doesn’t match the disk")
    }

    func testMalformedOrInconsistentReceiptsProveNothing() throws {
      let journal = receiptJournal()
      for receipt in [
        Data("{}".utf8),
        Data(#"{"plan_digest":"\#(Self.planDigest)","partitions":[]}"#.utf8),
        journal.receipt!.dropLast(),
      ] {
        XCTAssertNil(
          RemovalInterruptedInstall.parse(
            transcript: journal.transcript, target: journal.target, receipt: receipt))
      }
      // The receipt's first partition must be the journal's startup container.
      var reordered = journal
      reordered.recorded!.swapAt(0, 1)
      XCTAssertNil(reordered.parsed)
      // Every partition must lie inside the plan's extent.
      var outside = journal
      outside.planLength -= 1
      XCTAssertNil(outside.parsed)
    }

    func testOnlyEnginesWithoutReceiptsFallBackToTheExtent() throws {
      var modern = journal()
      modern.engine = Self.receiptEngine
      let record = try XCTUnwrap(modern.parsed)
      XCTAssertFalse(record.predatesPartitionReceipts)
      assertRefusal(
        strandedDisk([record]), "its EFI partition has no readable asahi/stub_info.json")
      for legacy in [
        Self.legacyEngine, "v0.9.2-omarchy.28", "v0.9.2-omarchy.20261105.0123456789ab",
      ] {
        var old = journal()
        old.engine = legacy
        XCTAssertTrue(try XCTUnwrap(old.parsed).predatesPartitionReceipts, legacy)
      }
    }

    // MARK: Reading the helper's directory

    func testJournalsAreReadOnlyFromAPrivateDirectoryWithoutFollowingLinks() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let directory = root.appendingPathComponent("execution-journals")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let journal = receiptJournal()
      let name = String(repeating: "1", count: 64) + ".jsonl"
      func write(_ data: Data, _ file: String) throws {
        let url = directory.appendingPathComponent(file)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
      try write(journal.transcript, name)
      try write(journal.target, name + ".apfs-target-prepared.evidence")
      try write(journal.receipt!, name + ".partitions.receipt")
      let read = { MacRemovalDiskOperator.interruptedInstalls(in: directory, owner: getuid()) }
      XCTAssertEqual(read(), [try XCTUnwrap(journal.parsed)])

      // Another owner's directory is not the helper's.
      XCTAssertEqual(MacRemovalDiskOperator.interruptedInstalls(in: directory, owner: 0), [])
      // A receipt that is a link proves nothing, even to a valid file.
      let receipt = directory.appendingPathComponent(name + ".partitions.receipt")
      try FileManager.default.removeItem(at: receipt)
      try FileManager.default.createSymbolicLink(
        at: receipt, withDestinationURL: directory.appendingPathComponent(name))
      XCTAssertEqual(read(), [])
      // Without a receipt, the journal alone still reads.
      try FileManager.default.removeItem(at: receipt)
      var bare = journal
      bare.recorded = nil
      XCTAssertEqual(read(), [try XCTUnwrap(bare.parsed)])
      // A writable or linked directory is never read.
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o777], ofItemAtPath: directory.path)
      XCTAssertEqual(read(), [])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let link = root.appendingPathComponent("linked")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
      XCTAssertEqual(MacRemovalDiskOperator.interruptedInstalls(in: link, owner: getuid()), [])
    }
  }
#endif

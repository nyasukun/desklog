import DesklogCore
import Foundation
import Testing

@Suite struct SpeakerIdentityStoreTests {
    @Test func confirmedProfileRejectsLooseMatchAndNeverDriftsAutomatically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)
        let original = try await store.identify(embedding: [1, 0])
        let observation = try await store.recordObservation(
            eventID: UUID(),
            timestamp: Date(),
            match: original,
            text: "本人の登録音声",
            embedding: [1, 0]
        )
        let confirmed = try await store.labelObservation(
            id: observation.id,
            name: "本人",
            isSelf: true
        )

        // Cosine distance 0.12 was accepted by the previous 0.32 threshold.
        let other = try await store.identify(embedding: [0.88, 0.47497368])
        #expect(other.profile.id != confirmed.profile.id)
        #expect(other.wasCreated)

        let same = try await store.identify(embedding: [0.999, 0.04471018])
        #expect(same.profile.id == confirmed.profile.id)
        let persisted = try await store.profiles().first { $0.id == confirmed.profile.id }
        #expect(persisted?.centroid == [1, 0])
        #expect(persisted?.sampleCount == 1)
    }

    @Test func explicitLabelReplacesAutomaticCentroidWithSelectedObservation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)
        let first = try await store.identify(embedding: [1, 0])
        _ = try await store.identify(embedding: [0.9, 0.4358899])
        let observation = try await store.recordObservation(
            eventID: UUID(),
            timestamp: Date(),
            match: first,
            text: "選択した本人音声",
            embedding: [1, 0]
        )

        let labeled = try await store.labelObservation(
            id: observation.id,
            name: "本人",
            isSelf: true
        )
        #expect(labeled.profile.centroid == [1, 0])
        #expect(labeled.profile.referenceEmbeddings == [[1, 0]])
        #expect(labeled.profile.sampleCount == 1)
    }

    @Test func labelingAMissedClusterWithAnExistingNameAddsAReferenceAnchor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)

        let original = try await store.identify(embedding: [1, 0])
        let originalObservation = try await store.recordObservation(
            eventID: UUID(),
            timestamp: Date(),
            match: original,
            text: "最初に登録した相澤さん",
            embedding: [1, 0]
        )
        _ = try await store.labelObservation(
            id: originalObservation.id,
            name: "相澤",
            isSelf: false
        )

        let missed = try await store.identify(embedding: [0, 1])
        #expect(missed.wasCreated)
        let missedObservation = try await store.recordObservation(
            eventID: UUID(),
            timestamp: Date(),
            match: missed,
            text: "別クラスタになった相澤さん",
            embedding: [0, 1]
        )
        let grouped = try await store.labelObservation(
            id: missedObservation.id,
            name: "相澤",
            isSelf: false
        )

        #expect(grouped.profile.id == original.profile.id)
        #expect(grouped.profile.alternateProfileIDs == [missed.profile.id])
        #expect(grouped.profile.referenceEmbeddings == [[1, 0], [0, 1]])
        #expect(grouped.observation.profileID == original.profile.id)
        #expect(try await store.profiles().count == 1)
    }

    @Test func legacyConfirmedProfileRestoresItsOriginalLabeledObservation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eventID = UUID()
        let store = SpeakerIdentityStore(rootDirectory: root)
        let match = try await store.identify(embedding: [1, 0])
        let observation = try await store.recordObservation(
            eventID: eventID,
            timestamp: Date(),
            match: match,
            text: "元の登録音声",
            embedding: [1, 0]
        )
        _ = try await store.labelObservation(
            id: observation.id,
            name: "本人",
            isSelf: true
        )

        // Model an on-disk profile from the previous schema.
        let profilesURL = root.appendingPathComponent("profiles.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: profilesURL)) as? [[String: Any]]
        )
        object[0].removeValue(forKey: "referenceEmbeddings")
        object[0]["centroid"] = [0.0, 1.0]
        object[0]["sampleCount"] = 15
        try JSONSerialization.data(withJSONObject: object).write(to: profilesURL, options: .atomic)

        let reloaded = SpeakerIdentityStore(rootDirectory: root)
        let restored = try await reloaded.restoreLegacyConfirmedReferences(
            eventIDByProfileID: [match.profile.id: eventID]
        )
        let profile = try #require(try await reloaded.profiles().first)
        #expect(restored)
        #expect(profile.centroid == [1, 0])
        #expect(profile.referenceEmbeddings == [[1, 0]])
        #expect(profile.sampleCount == 1)
    }

    @Test func profileCanBeRenamedDirectlyAndSelfTagMovesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)
        let first = try await store.identify(embedding: [1, 0, 0])
        let second = try await store.identify(embedding: [0, 1, 0])

        _ = try await store.updateProfile(id: first.profile.id, name: "山田", isSelf: true)
        let updated = try await store.updateProfile(id: second.profile.id, name: "佐藤", isSelf: true)
        let profiles = try await store.profiles()

        #expect(updated.name == "佐藤")
        #expect(updated.isSelf)
        #expect(profiles.filter(\.isSelf).map(\.id) == [second.profile.id])

        let renamed = try await store.updateProfile(id: second.profile.id, name: "  佐藤   花子  ", isSelf: true)
        #expect(renamed.name == "佐藤 花子")
    }

    @Test func assigningAnExistingNameGroupsVoiceClustersForFutureMatching() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)
        let first = try await store.identify(embedding: [1, 0])
        let second = try await store.identify(embedding: [0, 1])
        let secondObservation = try await store.recordObservation(
            eventID: UUID(),
            timestamp: Date(),
            match: second,
            text: "別の声質で検出された相澤さん",
            embedding: [0, 1]
        )

        _ = try await store.updateProfile(id: first.profile.id, name: "相澤", isSelf: false)
        let grouped = try await store.updateProfile(
            id: second.profile.id,
            name: "相澤",
            isSelf: false
        )

        let profiles = try await store.profiles()
        #expect(profiles.count == 1)
        #expect(grouped.id == first.profile.id)
        #expect(grouped.alternateProfileIDs == [second.profile.id])
        #expect(grouped.referenceEmbeddings == [[1, 0], [0, 1]])

        let rematched = try await store.identify(embedding: [0, 1])
        #expect(rematched.profile.id == grouped.id)
        #expect(!rematched.wasCreated)
        let migratedObservation = try #require(
            try await store.recentObservations().first { $0.id == secondObservation.id }
        )
        #expect(migratedObservation.profileID == grouped.id)
    }

    @Test func existingDuplicateNamesAreConsolidatedDuringMigration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogSpeakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(rootDirectory: root)
        let first = try await store.identify(embedding: [1, 0])
        let second = try await store.identify(embedding: [0, 1])
        _ = try await store.updateProfile(id: first.profile.id, name: "相澤", isSelf: false)
        _ = try await store.updateProfile(id: second.profile.id, name: "旧名", isSelf: false)

        let profilesURL = root.appendingPathComponent("profiles.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: profilesURL)) as? [[String: Any]]
        )
        object[1]["name"] = "相澤"
        try JSONSerialization.data(withJSONObject: object).write(to: profilesURL, options: .atomic)

        let reloaded = SpeakerIdentityStore(rootDirectory: root)
        #expect(try await reloaded.consolidateProfilesWithMatchingNames())
        let consolidated = try #require(try await reloaded.profiles().first)
        #expect(try await reloaded.profiles().count == 1)
        #expect(consolidated.name == "相澤")
        #expect(consolidated.alternateProfileIDs == [second.profile.id])
        #expect(consolidated.referenceEmbeddings == [[1, 0], [0, 1]])
    }
}

import Foundation

public actor SpeakerIdentityStore {
    /// Cross-recording speaker embeddings vary more than embeddings clustered
    /// within one recording. Prefer creating an extra unknown profile over
    /// silently attributing another person's words to an existing identity.
    public nonisolated static let defaultMatchThreshold: Float = 0.14
    public nonisolated static let confirmedMatchThreshold: Float = 0.10

    public nonisolated let rootDirectory: URL
    private var profilesCache: [SpeakerProfile]?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? WorklogStore.defaultRootDirectory
            .appendingPathComponent("speakers", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func profiles() throws -> [SpeakerProfile] {
        try loadProfiles().sorted { $0.id < $1.id }
    }

    /// Consolidates profiles that the user has assigned the same normalized
    /// name. Each former cluster becomes an alternate ID and its confirmed
    /// embeddings become additional anchors for the canonical person.
    ///
    /// This also migrates data produced by older builds, which could leave two
    /// profile cards named for the same person.
    @discardableResult
    public func consolidateProfilesWithMatchingNames(
        at date: Date = Date()
    ) throws -> Bool {
        var profiles = try loadProfiles()
        let migrations = Self.consolidateMatchingNames(in: &profiles, at: date)
        guard !migrations.isEmpty else { return false }
        try saveProfiles(profiles)
        try apply(migrations)
        return true
    }

    public func identify(
        embedding: [Float],
        threshold: Float = SpeakerIdentityStore.defaultMatchThreshold,
        at date: Date = Date()
    ) throws -> SpeakerMatch {
        try Self.validate(embedding)
        var profiles = try loadProfiles()
        let nearest = profiles.enumerated()
            .compactMap { index, profile -> (Int, Float)? in
                guard profile.centroid.count == embedding.count else { return nil }
                let references = profile.referenceEmbeddings.filter {
                    $0.count == embedding.count
                }
                let candidates = references.isEmpty ? [profile.centroid] : references
                guard let distance = candidates.map({
                    Self.cosineDistance($0, embedding)
                }).min() else { return nil }
                return (index, distance)
            }
            .min { $0.1 < $1.1 }

        if let (index, distance) = nearest {
            let effectiveThreshold = profiles[index].isConfirmed
                ? min(threshold, Self.confirmedMatchThreshold)
                : threshold
            if distance <= effectiveThreshold {
                // A named profile changes only when the user explicitly labels
                // another observation. Automatic matches must never drag a
                // confirmed identity toward a different voice.
                if !profiles[index].isConfirmed {
                    profiles[index].centroid = Self.weightedAverage(
                        profiles[index].centroid,
                        count: profiles[index].sampleCount,
                        with: embedding
                    )
                    profiles[index].sampleCount += 1
                    profiles[index].updatedAt = date
                    try saveProfiles(profiles)
                }
                return .init(profile: profiles[index], distance: distance, wasCreated: false)
            }
        }

        let profile = SpeakerProfile(
            id: try allocateSpeakerID(from: profiles),
            centroid: embedding,
            createdAt: date,
            updatedAt: date
        )
        profiles.append(profile)
        try saveProfiles(profiles)
        return .init(profile: profile, distance: nil, wasCreated: true)
    }

    public func recordObservation(
        eventID: UUID,
        timestamp: Date,
        match: SpeakerMatch,
        text: String,
        embedding: [Float]
    ) throws -> SpeakerObservation {
        try prepare()
        let observation = SpeakerObservation(
            eventID: eventID,
            timestamp: timestamp,
            profileID: match.profile.id,
            text: text,
            embedding: embedding,
            distance: match.distance
        )
        let url = observationsDirectory.appendingPathComponent("\(observation.id.uuidString).json")
        try writePrivate(encoder.encode(observation), to: url)
        return observation
    }

    public func recentObservations(limit: Int = 50) throws -> [SpeakerObservation] {
        try prepare()
        let urls = try FileManager.default.contentsOfDirectory(
            at: observationsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        return urls.compactMap { url in
            try? decoder.decode(SpeakerObservation.self, from: Data(contentsOf: url))
        }
        .sorted { $0.timestamp > $1.timestamp }
        .prefix(max(0, limit))
        .map { $0 }
    }

    public func labelObservation(
        id observationID: UUID,
        name: String,
        isSelf: Bool,
        at date: Date = Date()
    ) throws -> SpeakerLabelResult {
        let trimmedName = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !trimmedName.isEmpty else { throw SpeakerIdentityError.emptyName }
        try prepare()
        let observationURL = observationsDirectory.appendingPathComponent("\(observationID.uuidString).json")
        var observation = try decoder.decode(
            SpeakerObservation.self,
            from: Data(contentsOf: observationURL)
        )
        var profiles = try loadProfiles()
        guard let sourceIndex = profiles.firstIndex(where: {
            $0.id == observation.profileID || $0.alternateProfileIDs.contains(observation.profileID)
        }) else {
            throw SpeakerIdentityError.profileNotFound
        }
        let sourceProfileID = observation.profileID
        let canonicalSourceProfileID = profiles[sourceIndex].id

        let destinationIndex = profiles.firstIndex {
            $0.id != canonicalSourceProfileID &&
                Self.namesMatch($0.name, trimmedName)
        }
        var migrations: [ProfileMigration] = []
        let provisionalProfileID: String
        if let destinationIndex {
            let source = profiles[sourceIndex]
            Self.addConfirmedReference(
                observation.embedding,
                to: &profiles[destinationIndex]
            )
            profiles[destinationIndex].name = trimmedName
            profiles[destinationIndex].isSelf = isSelf
            profiles[destinationIndex].alternateProfileIDs = Array(Set(
                profiles[destinationIndex].alternateProfileIDs +
                    source.alternateProfileIDs +
                    [source.id]
            )).sorted()
            profiles[destinationIndex].updatedAt = date
            let destinationID = profiles[destinationIndex].id
            migrations.append(.init(
                sourceIDs: [source.id] + source.alternateProfileIDs,
                destinationID: destinationID
            ))
            profiles.removeAll { $0.id == canonicalSourceProfileID }
            provisionalProfileID = destinationID
        } else {
            profiles[sourceIndex].name = trimmedName
            profiles[sourceIndex].isSelf = isSelf
            // The selected observation is the voice sample the user actually
            // confirmed. Discard any centroid drift accumulated while this
            // profile was still an automatic, unnamed cluster.
            profiles[sourceIndex].centroid = observation.embedding
            profiles[sourceIndex].sampleCount = 1
            profiles[sourceIndex].referenceEmbeddings = [observation.embedding]
            profiles[sourceIndex].updatedAt = date
            provisionalProfileID = profiles[sourceIndex].id
        }

        migrations += Self.consolidateMatchingNames(in: &profiles, at: date)
        guard let finalIndex = profiles.firstIndex(where: {
            $0.id == provisionalProfileID ||
                $0.alternateProfileIDs.contains(provisionalProfileID)
        }) else {
            throw SpeakerIdentityError.profileNotFound
        }
        // The explicit label action wins if consolidated profiles disagreed on
        // display spelling or on the self tag.
        profiles[finalIndex].name = trimmedName
        profiles[finalIndex].isSelf = isSelf
        profiles[finalIndex].updatedAt = date
        if isSelf {
            for index in profiles.indices where index != finalIndex {
                profiles[index].isSelf = false
            }
        }
        let finalProfile = profiles[finalIndex]
        try saveProfiles(profiles)
        try apply(migrations)
        observation.profileID = finalProfile.id
        try writePrivate(encoder.encode(observation), to: observationURL)
        return SpeakerLabelResult(
            profile: finalProfile,
            observation: observation,
            sourceProfileID: sourceProfileID
        )
    }

    /// Updates a speaker profile without requiring the user to find one of its
    /// historical observations. Assigning an existing name means "this voice
    /// cluster is that person", so matching profiles are consolidated and all
    /// of their confirmed samples participate in later identification.
    public func updateProfile(
        id profileID: String,
        name: String,
        isSelf: Bool,
        at date: Date = Date()
    ) throws -> SpeakerProfile {
        let trimmedName = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !trimmedName.isEmpty else { throw SpeakerIdentityError.emptyName }
        var profiles = try loadProfiles()
        guard let profileIndex = profiles.firstIndex(where: {
            $0.id == profileID || $0.alternateProfileIDs.contains(profileID)
        }) else {
            throw SpeakerIdentityError.profileNotFound
        }

        let sourceProfileID = profiles[profileIndex].id
        let wasConfirmed = profiles[profileIndex].isConfirmed
        profiles[profileIndex].name = trimmedName
        profiles[profileIndex].isSelf = isSelf
        if !wasConfirmed, profiles[profileIndex].referenceEmbeddings.isEmpty {
            profiles[profileIndex].referenceEmbeddings = [profiles[profileIndex].centroid]
            profiles[profileIndex].sampleCount = 1
        }
        profiles[profileIndex].updatedAt = date
        let migrations = Self.consolidateMatchingNames(in: &profiles, at: date)
        guard let finalIndex = profiles.firstIndex(where: {
            $0.id == sourceProfileID || $0.alternateProfileIDs.contains(sourceProfileID)
        }) else {
            throw SpeakerIdentityError.profileNotFound
        }
        profiles[finalIndex].name = trimmedName
        profiles[finalIndex].isSelf = isSelf
        profiles[finalIndex].updatedAt = date
        if isSelf {
            for index in profiles.indices where index != finalIndex {
                profiles[index].isSelf = false
            }
        }
        try saveProfiles(profiles)
        try apply(migrations)
        return profiles[finalIndex]
    }

    /// Restores explicit reference samples for profiles created before
    /// `referenceEmbeddings` was persisted. The controller derives the mapping
    /// from immutable speaker-label events, whose target is the exact
    /// observation the user originally selected.
    @discardableResult
    public func restoreLegacyConfirmedReferences(
        eventIDByProfileID: [String: UUID],
        at date: Date = Date()
    ) throws -> Bool {
        guard !eventIDByProfileID.isEmpty else { return false }
        var profiles = try loadProfiles()
        let missingIDs = Set(profiles.filter {
            $0.isConfirmed && $0.referenceEmbeddings.isEmpty
        }.map(\.id))
        guard !missingIDs.isEmpty else { return false }

        try prepare()
        let observations = try FileManager.default.contentsOfDirectory(
            at: observationsDirectory,
            includingPropertiesForKeys: nil
        ).compactMap { url -> SpeakerObservation? in
            guard url.pathExtension == "json" else { return nil }
            return try? decoder.decode(
                SpeakerObservation.self,
                from: Data(contentsOf: url)
            )
        }
        var didChange = false
        for index in profiles.indices where missingIDs.contains(profiles[index].id) {
            guard let eventID = eventIDByProfileID[profiles[index].id],
                  let observation = observations.first(where: { $0.eventID == eventID }),
                  observation.embedding.count == profiles[index].centroid.count else {
                continue
            }
            profiles[index].centroid = observation.embedding
            profiles[index].referenceEmbeddings = [observation.embedding]
            profiles[index].sampleCount = 1
            profiles[index].updatedAt = date
            didChange = true
        }
        if didChange { try saveProfiles(profiles) }
        return didChange
    }

    private var profilesURL: URL {
        rootDirectory.appendingPathComponent("profiles.json")
    }

    private var observationsDirectory: URL {
        rootDirectory.appendingPathComponent("observations", isDirectory: true)
    }

    private var nextSpeakerSequenceURL: URL {
        rootDirectory.appendingPathComponent("next-speaker-sequence")
    }

    private func prepare() throws {
        try makePrivateDirectory(rootDirectory)
        try makePrivateDirectory(observationsDirectory)
    }

    private func loadProfiles() throws -> [SpeakerProfile] {
        if let profilesCache { return profilesCache }
        try prepare()
        guard FileManager.default.fileExists(atPath: profilesURL.path) else {
            profilesCache = []
            return []
        }
        let profiles = try decoder.decode([SpeakerProfile].self, from: Data(contentsOf: profilesURL))
        profilesCache = profiles
        return profiles
    }

    private func saveProfiles(_ profiles: [SpeakerProfile]) throws {
        try prepare()
        try writePrivate(encoder.encode(profiles), to: profilesURL)
        profilesCache = profiles
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func allocateSpeakerID(from profiles: [SpeakerProfile]) throws -> String {
        try prepare()
        let allKnownIDs = profiles.flatMap { [$0.id] + $0.alternateProfileIDs }
        let existingIDs = Set(allKnownIDs)
        let derivedNext = (allKnownIDs.compactMap(Self.sequence(from:)).max() ?? 0) + 1
        let persistedNext = (try? String(contentsOf: nextSpeakerSequenceURL, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var sequence = max(1, derivedNext, persistedNext ?? 1)
        while existingIDs.contains(Self.speakerID(sequence)) {
            sequence += 1
        }
        try writePrivate(Data("\(sequence + 1)\n".utf8), to: nextSpeakerSequenceURL)
        return Self.speakerID(sequence)
    }

    private func migrateObservations(from sourceProfileID: String, to destinationProfileID: String) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: observationsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        for url in urls {
            guard var stored = try? decoder.decode(
                SpeakerObservation.self,
                from: Data(contentsOf: url)
            ), stored.profileID == sourceProfileID else { continue }
            stored.profileID = destinationProfileID
            try writePrivate(encoder.encode(stored), to: url)
        }
    }

    private func apply(_ migrations: [ProfileMigration]) throws {
        for migration in migrations {
            for sourceID in Set(migration.sourceIDs) where sourceID != migration.destinationID {
                try migrateObservations(
                    from: sourceID,
                    to: migration.destinationID
                )
            }
        }
    }

    private struct ProfileMigration {
        let sourceIDs: [String]
        let destinationID: String
    }

    /// Repeatedly merges equal named profiles. The oldest profile remains the
    /// canonical ID, keeping existing logs and UI references as stable as
    /// possible.
    private static func consolidateMatchingNames(
        in profiles: inout [SpeakerProfile],
        at date: Date
    ) -> [ProfileMigration] {
        var migrations: [ProfileMigration] = []

        while let pair = firstMatchingNamePair(in: profiles) {
            let lhs = profiles[pair.0]
            let rhs = profiles[pair.1]
            let destinationIndex: Int
            let sourceIndex: Int
            if lhs.createdAt < rhs.createdAt ||
                (lhs.createdAt == rhs.createdAt && lhs.id < rhs.id) {
                destinationIndex = pair.0
                sourceIndex = pair.1
            } else {
                destinationIndex = pair.1
                sourceIndex = pair.0
            }

            let source = profiles[sourceIndex]
            let destinationID = profiles[destinationIndex].id
            let sourceReferences = source.referenceEmbeddings.isEmpty
                ? [source.centroid]
                : source.referenceEmbeddings
            for reference in sourceReferences {
                addConfirmedReference(reference, to: &profiles[destinationIndex])
            }
            profiles[destinationIndex].isSelf =
                profiles[destinationIndex].isSelf || source.isSelf
            profiles[destinationIndex].alternateProfileIDs = Array(Set(
                profiles[destinationIndex].alternateProfileIDs +
                    source.alternateProfileIDs +
                    [source.id]
            )).filter { $0 != destinationID }.sorted()
            profiles[destinationIndex].updatedAt = date
            migrations.append(.init(
                sourceIDs: [source.id] + source.alternateProfileIDs,
                destinationID: destinationID
            ))
            profiles.remove(at: sourceIndex)
        }

        return migrations
    }

    private static func firstMatchingNamePair(
        in profiles: [SpeakerProfile]
    ) -> (Int, Int)? {
        guard profiles.count > 1 else { return nil }
        for lhs in profiles.indices {
            guard profiles[lhs].isConfirmed else { continue }
            for rhs in profiles.indices where rhs > lhs {
                if namesMatch(profiles[lhs].name, profiles[rhs].name) {
                    return (lhs, rhs)
                }
            }
        }
        return nil
    }

    private static func namesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = lhs.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let right = rhs.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.localizedCaseInsensitiveCompare(right) == .orderedSame
    }

    private static func sequence(from speakerID: String) -> Int? {
        guard speakerID.hasPrefix("Speaker-") else { return nil }
        return Int(speakerID.dropFirst("Speaker-".count))
    }

    private static func speakerID(_ sequence: Int) -> String {
        String(format: "Speaker-%03d", sequence)
    }

    private static func validate(_ embedding: [Float]) throws {
        guard !embedding.isEmpty else { throw SpeakerIdentityError.emptyEmbedding }
        guard embedding.allSatisfy(\.isFinite), embedding.contains(where: { abs($0) > .ulpOfOne }) else {
            throw SpeakerIdentityError.invalidEmbedding
        }
    }

    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for (left, right) in zip(lhs, rhs) {
            dot += left * right
            leftNorm += left * left
            rightNorm += right * right
        }
        guard leftNorm > 0, rightNorm > 0 else { return 1 }
        return max(0, min(2, 1 - dot / sqrt(leftNorm * rightNorm)))
    }

    private static func weightedAverage(_ current: [Float], count: Int, with value: [Float]) -> [Float] {
        merge(current, count: count, with: value, otherCount: 1)
    }

    private static func addConfirmedReference(
        _ embedding: [Float],
        to profile: inout SpeakerProfile
    ) {
        let references = profile.referenceEmbeddings.isEmpty
            ? [profile.centroid]
            : profile.referenceEmbeddings
        if references.contains(where: {
            $0.count == embedding.count && cosineDistance($0, embedding) <= 0.01
        }) {
            profile.referenceEmbeddings = references
        } else {
            profile.referenceEmbeddings = Array((references + [embedding]).suffix(12))
        }
        profile.sampleCount = profile.referenceEmbeddings.count
        let compatibleReferences = profile.referenceEmbeddings.filter {
            $0.count == profile.centroid.count
        }
        guard let first = compatibleReferences.first else {
            profile.centroid = embedding
            return
        }
        profile.centroid = compatibleReferences.dropFirst().reduce(first) { current, value in
            zip(current, value).map(+)
        }.map { $0 / Float(compatibleReferences.count) }
    }

    private static func merge(_ lhs: [Float], count: Int, with rhs: [Float], otherCount: Int) -> [Float] {
        guard lhs.count == rhs.count else { return lhs }
        let total = Float(max(1, count + otherCount))
        return zip(lhs, rhs).map {
            ($0 * Float(count) + $1 * Float(otherCount)) / total
        }
    }
}

public enum SpeakerIdentityError: LocalizedError {
    case emptyEmbedding
    case invalidEmbedding
    case emptyName
    case profileNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyEmbedding: return "話者特徴量がありません。"
        case .invalidEmbedding: return "話者特徴量が不正です。"
        case .emptyName: return "話者名を入力してください。"
        case .profileNotFound: return "話者プロファイルが見つかりません。"
        }
    }
}

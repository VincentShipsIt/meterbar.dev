import Foundation
import MeterBarShared

/// Validity stamp a cached parse is checked against before it is trusted.
///
/// Size *and* modification time, plus the file identifier when the volume
/// reports one. A stale hit is the single failure mode this cache cannot
/// tolerate — the numbers on the dashboard are the product — so the stamp errs
/// toward re-parsing: any field that moved invalidates the entry.
nonisolated struct CostScanFileStamp: Codable, Equatable, Sendable {
    let size: Int64
    /// Seconds since 1970. Only ever compared against another stamp, never
    /// converted back into a `Date` for bucketing, so the epoch choice is free.
    let modified: Double
    /// `st_ino`, when the filesystem supplies one. Optional because a volume
    /// that reports no file number should still be cacheable on size + mtime.
    let fileID: UInt64?

    static func read(at url: URL) -> CostScanFileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return CostScanFileStamp(
            size: size,
            modified: modified.timeIntervalSince1970,
            fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    /// `fileID` participates only when both sides carry one: an entry written on
    /// a volume that reported no file number must not be invalidated forever
    /// just because the current read produced one (or the reverse).
    func matches(_ other: CostScanFileStamp) -> Bool {
        guard size == other.size, modified == other.modified else { return false }
        guard let lhs = fileID, let rhs = other.fileID else { return true }
        return lhs == rhs
    }
}

/// Append-only interning table, so a digest stores each model/origin/project
/// string once and refers to it by index everywhere else.
nonisolated struct CostScanStringTable {
    private(set) var values: [String] = []
    private var indexes: [String: Int] = [:]

    mutating func index(of value: String) -> Int {
        if let existing = indexes[value] { return existing }
        let index = values.count
        indexes[value] = index
        values.append(value)
        return index
    }
}

/// One Claude Code transcript, reduced to per-day (model, origin) token buckets.
///
/// Day granularity is what makes the cache survive a moving cutoff. The period
/// window always starts at local midnight (`CostWindow.start(days:)`), so a
/// day's bucket is wholly inside or wholly outside any window the app can ask
/// for — both windows re-derive from the same cutoff-independent payload, and
/// tomorrow's scan reuses today's entry instead of invalidating it.
nonisolated struct ClaudeTranscriptDigest: Codable, Equatable, Sendable {
    /// One local day of a transcript.
    nonisolated struct Day: Codable, Equatable, Sendable {
        /// `Date.timeIntervalSinceReferenceDate` of `startOfDay`.
        ///
        /// Reference-date seconds rather than Unix seconds on purpose: `Date`
        /// stores this value verbatim, so it round-trips bit-exactly. Going via
        /// the 1970 epoch adds ~9.8e8 and can cost a mantissa bit, which would
        /// shift a reconstructed `periodStart` by an ulp against the cold scan.
        let day: Double
        let earliest: Double
        let latest: Double
        /// Flat rows of `bucketStride` integers, one row per (model, origin)
        /// pair seen on this day. Flat rather than an array of structs so the
        /// on-disk form is a bare number array.
        let buckets: [Int]
    }

    /// `modelIndex`, `originIndex`, `input`, `output`, `cacheCreation`,
    /// `cacheCreationOneHour`, `cacheRead`, `events`.
    static let bucketStride = 8

    let projectID: String
    /// Raw model strings, exactly as the transcript spelled them. Pricing and
    /// display names are both derived at reconstruction time, so editing
    /// `ModelPricing` can never surface a stale cached cost.
    let models: [String]
    let origins: [String]
    let days: [Day]

    /// Number of scalars this entry occupies on disk. Drives the cache budget.
    var valueCount: Int {
        days.reduce(0) { $0 + 3 + $1.buckets.count }
    }

    /// Rebuilds a window's tally from the buckets, or `nil` when the payload is
    /// malformed — a truncated bucket row or an out-of-range string index means
    /// the entry cannot be trusted, and a full re-parse is always the safe
    /// answer.
    ///
    /// `cutoff` must land on a local day boundary; the caller enforces that.
    func totals(since cutoff: Date) -> ClaudeSessionTotals? {
        var totals = ClaudeSessionTotals()

        for storedDay in days {
            guard storedDay.buckets.count.isMultiple(of: Self.bucketStride) else { return nil }
            let dayStart = Date(timeIntervalSinceReferenceDate: storedDay.day)
            let included = dayStart >= cutoff

            var offset = 0
            while offset < storedDay.buckets.count {
                guard let bucket = self.bucket(in: storedDay, at: offset) else { return nil }
                if included {
                    Self.accumulate(bucket, on: dayStart, projectID: projectID, into: &totals)
                }
                offset += Self.bucketStride
            }

            if included {
                totals.note(Date(timeIntervalSinceReferenceDate: storedDay.earliest))
                totals.note(Date(timeIntervalSinceReferenceDate: storedDay.latest))
            }
        }

        // Matches `ClaudeCostScanner.tally`: one *file* is one session.
        totals.sessions = totals.hasUsage ? 1 : 0
        return totals
    }

    private struct Bucket {
        let model: String?
        let origin: String
        let input: Int
        let output: Int
        let cacheCreation: Int
        let cacheCreationOneHour: Int
        let cacheRead: Int
        let events: Int
    }

    private func bucket(in day: Day, at offset: Int) -> Bucket? {
        let modelIndex = day.buckets[offset]
        let originIndex = day.buckets[offset + 1]
        guard origins.indices.contains(originIndex) else { return nil }
        let model: String?
        if modelIndex == Self.nilModelIndex {
            model = nil
        } else {
            guard models.indices.contains(modelIndex) else { return nil }
            model = models[modelIndex]
        }
        return Bucket(
            model: model,
            origin: origins[originIndex],
            input: day.buckets[offset + 2],
            output: day.buckets[offset + 3],
            cacheCreation: day.buckets[offset + 4],
            cacheCreationOneHour: day.buckets[offset + 5],
            cacheRead: day.buckets[offset + 6],
            events: day.buckets[offset + 7]
        )
    }

    /// Sentinel for a transcript line that carried usage but no model name.
    static let nilModelIndex = -1

    /// Folds one bucket in exactly where `ClaudeCostScanner.tally` folds its
    /// events.
    ///
    /// Pricing is applied once to the bucket's summed tokens rather than once
    /// per event. That is valid because every token field is non-negative (the
    /// digest refuses to cache a transcript where one is not) and
    /// `calculateClaudeCost` is then linear in each count, with the
    /// `min(oneHour, cacheCreation)` clamp already satisfied per event. The only
    /// difference from the cold path is floating-point reassociation — and
    /// summing tokens before pricing is the more accurate of the two.
    private static func accumulate(
        _ bucket: Bucket,
        on day: Date,
        projectID: String,
        into totals: inout ClaudeSessionTotals
    ) {
        let cost = TokenCostMath.calculateClaudeCost(
            input: bucket.input,
            output: bucket.output,
            cacheCreation: bucket.cacheCreation,
            cacheCreationOneHour: bucket.cacheCreationOneHour,
            cacheRead: bucket.cacheRead,
            pricing: ModelPricing.claude(for: bucket.model)
        )
        let displayModel = CostScanValues.displayModelName(bucket.model)

        totals.input += bucket.input
        totals.output += bucket.output
        totals.cacheCreation += bucket.cacheCreation
        totals.cacheRead += bucket.cacheRead
        totals.estimatedCost += cost

        var tokens = TokenAccumulator()
        tokens.add(
            input: bucket.input,
            output: bucket.output,
            cacheCreation: bucket.cacheCreation,
            cacheRead: bucket.cacheRead,
            estimatedCostUSD: cost,
            events: bucket.events
        )

        totals.daily[day, default: TokenAccumulator()].merge(tokens)
        totals.dailyModels[day, default: [:]][displayModel, default: TokenAccumulator()].merge(tokens)
        totals.dailyProjects[day, default: [:]][projectID, default: TokenAccumulator()].merge(tokens)
        var dailyProjectModels = totals.dailyProjectModels[day] ?? [:]
        dailyProjectModels[projectID, default: [:]][displayModel, default: TokenAccumulator()].merge(tokens)
        totals.dailyProjectModels[day] = dailyProjectModels
        totals.models[displayModel, default: TokenAccumulator()].merge(tokens)
        totals.origins[bucket.origin, default: TokenAccumulator()].merge(tokens)
        totals.projects[projectID, default: TokenAccumulator()].merge(tokens)
        totals.projectModels[projectID, default: [:]][displayModel, default: TokenAccumulator()].merge(tokens)
    }
}

/// One cached Claude transcript: where it lives, how to tell it changed, and
/// what it contained.
nonisolated struct ClaudeCacheEntry: Codable, Equatable, Sendable {
    let path: String
    let stamp: CostScanFileStamp
    let digest: ClaudeTranscriptDigest
}

/// One deduplicated Codex usage event, in the shape the tally consumes.
///
/// Codex is cached at event rather than day granularity because its dedup key
/// includes the event timestamp in milliseconds: collapsing events into buckets
/// would lose the information the deduplicator needs. Replaying records through
/// the same `apply` the cold path uses makes a warm scan exact by construction,
/// not by argument.
nonisolated struct CodexUsageRecord: Sendable {
    let timestamp: Date
    let sessionID: String
    let model: String?
    let origin: String?
    let projectID: String
    let input: Int
    let cached: Int
    let output: Int
    let reasoning: Int
}

/// One Codex rollout's usage events, with the repeated strings interned.
nonisolated struct CodexRolloutDigest: Codable, Equatable, Sendable {
    /// `sessionIndex`, `modelIndex`, `originIndex`, `projectIndex`, `input`,
    /// `cached`, `output`, `reasoning`.
    static let fieldStride = 8
    /// Sentinel for a record with no model or no originator.
    static let missingIndex = -1

    let sessions: [String]
    let models: [String]
    let origins: [String]
    let projects: [String]
    /// `Date.timeIntervalSinceReferenceDate`, one per record — see
    /// `ClaudeTranscriptDigest.Day.day` for why the reference epoch matters.
    let timestamps: [Double]
    let fields: [Int]

    var valueCount: Int {
        timestamps.count + fields.count
    }

    init(records: [CodexUsageRecord]) {
        var sessions = CostScanStringTable()
        var models = CostScanStringTable()
        var origins = CostScanStringTable()
        var projects = CostScanStringTable()
        var timestamps: [Double] = []
        var fields: [Int] = []
        timestamps.reserveCapacity(records.count)
        fields.reserveCapacity(records.count * Self.fieldStride)

        for record in records {
            timestamps.append(record.timestamp.timeIntervalSinceReferenceDate)
            fields.append(sessions.index(of: record.sessionID))
            fields.append(record.model.map { models.index(of: $0) } ?? Self.missingIndex)
            fields.append(record.origin.map { origins.index(of: $0) } ?? Self.missingIndex)
            fields.append(projects.index(of: record.projectID))
            fields.append(record.input)
            fields.append(record.cached)
            fields.append(record.output)
            fields.append(record.reasoning)
        }

        self.sessions = sessions.values
        self.models = models.values
        self.origins = origins.values
        self.projects = projects.values
        self.timestamps = timestamps
        self.fields = fields
    }

    /// Rebuilds the events, or `nil` when the payload is malformed.
    func records() -> [CodexUsageRecord]? {
        guard fields.count == timestamps.count * Self.fieldStride else { return nil }

        var records: [CodexUsageRecord] = []
        records.reserveCapacity(timestamps.count)

        for index in timestamps.indices {
            let offset = index * Self.fieldStride
            let sessionIndex = fields[offset]
            let modelIndex = fields[offset + 1]
            let originIndex = fields[offset + 2]
            let projectIndex = fields[offset + 3]
            guard sessions.indices.contains(sessionIndex),
                  projects.indices.contains(projectIndex),
                  modelIndex == Self.missingIndex || models.indices.contains(modelIndex),
                  originIndex == Self.missingIndex || origins.indices.contains(originIndex) else {
                return nil
            }
            records.append(
                CodexUsageRecord(
                    timestamp: Date(timeIntervalSinceReferenceDate: timestamps[index]),
                    sessionID: sessions[sessionIndex],
                    model: modelIndex == Self.missingIndex ? nil : models[modelIndex],
                    origin: originIndex == Self.missingIndex ? nil : origins[originIndex],
                    projectID: projects[projectIndex],
                    input: fields[offset + 4],
                    cached: fields[offset + 5],
                    output: fields[offset + 6],
                    reasoning: fields[offset + 7]
                )
            )
        }
        return records
    }
}

/// One cached Codex rollout.
nonisolated struct CodexCacheEntry: Codable, Equatable, Sendable {
    let path: String
    let stamp: CostScanFileStamp
    let digest: CodexRolloutDigest
}

/// On-disk shape of the incremental scan cache.
nonisolated struct CostScanCacheFile: Codable, Sendable {
    /// Bumped whenever a scanner change alters what a digest means. There is no
    /// migration path by design: an entry written under different rules could
    /// produce a silently wrong total, and a slow scan beats a wrong number.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// The parsing and pricing rules these digests were produced under. Separate
    /// from `schemaVersion`, which describes the *container*: the layout can stay
    /// identical while the numbers inside it come to mean something different.
    let parserVersion: Int
    /// Claude entries are bucketed into *local* days, so a machine that changed
    /// time zone must re-derive them. Recorded at file level because the whole
    /// Claude half shares the fate.
    let timeZoneIdentifier: String
    let claude: [ClaudeCacheEntry]
    let codex: [CodexCacheEntry]

    init(timeZoneIdentifier: String, claude: [ClaudeCacheEntry], codex: [CodexCacheEntry]) {
        schemaVersion = Self.currentSchemaVersion
        parserVersion = CostScanValues.costCacheParserVersion
        self.timeZoneIdentifier = timeZoneIdentifier
        self.claude = claude
        self.codex = codex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // Required, unlike the entry lists below: those tolerate a truncated
        // write because a partial cache is still a correct cache. A payload with
        // no producer stamp is one this build cannot vouch for at all, so it must
        // fail to decode rather than default to "probably mine".
        parserVersion = try container.decode(Int.self, forKey: .parserVersion)
        timeZoneIdentifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
        claude = try container.decodeIfPresent([ClaudeCacheEntry].self, forKey: .claude) ?? []
        codex = try container.decodeIfPresent([CodexCacheEntry].self, forKey: .codex) ?? []
    }
}

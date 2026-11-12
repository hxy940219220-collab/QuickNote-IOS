import Combine
import Darwin
import Foundation
import NaturalLanguage

enum NoteIndexChange: Sendable {
    case saved(NoteIndexSnapshot)
    case removed(UUID)
}

struct NoteIndexModel: Codable, Equatable, Sendable {
    let identifier: String
    let revision: Int
    let dimension: Int
}

struct NoteIndexEmbedding: Sendable {
    let model: NoteIndexModel
    let vector: @Sendable (String) -> [Float]?

    static func localChinese() -> Self? {
        guard let local = LocalChineseEmbedding() else { return nil }
        return .init(model: local.identity, vector: { local.vector(for: $0) })
    }
}

// The framework object is accessed only while holding the lock.
private final class LocalChineseEmbedding: @unchecked Sendable {
    private let lock = NSLock()
    private let model: NLContextualEmbedding
    let identity: NoteIndexModel
    private let byteBudget: Int

    init?() {
        guard let model = NLContextualEmbedding(language: .simplifiedChinese), model.hasAvailableAssets,
              model.dimension > 0, model.maximumSequenceLength > 12 else { return nil }
        do { try model.load() } catch { return nil }
        self.model = model
        identity = .init(identifier: model.modelIdentifier, revision: model.revision, dimension: model.dimension)
        // The embedding API does not expose its subword tokenizer. A conservative UTF-8 budget
        // keeps segments short even for mixed CJK, Latin, and emoji input and leaves room for special tokens.
        byteBudget = model.maximumSequenceLength - 8
    }

    func vector(for text: String) -> [Float]? {
        lock.withLock {
            var total = Array(repeating: 0.0, count: identity.dimension)
            var tokenCount = 0
            var segment = String.UnicodeScalarView()
            var bytes = 0

            func accumulate() -> Bool {
                let part = String(segment)
                guard !part.isEmpty else { return true }
                guard let result = try? model.embeddingResult(for: part, language: .simplifiedChinese) else { return false }
                result.enumerateTokenVectors(in: part.startIndex..<part.endIndex) { vector, _ in
                    guard vector.count == total.count, vector.allSatisfy(\.isFinite) else { return true }
                    for index in total.indices { total[index] += vector[index] }
                    tokenCount += 1
                    return true
                }
                segment.removeAll(keepingCapacity: true)
                bytes = 0
                return true
            }

            for scalar in text.unicodeScalars {
                let size = String(scalar).utf8.count
                if bytes + size > byteBudget, !accumulate() { return nil }
                segment.append(scalar)
                bytes += size
            }
            guard accumulate(), tokenCount > 0 else { return nil }
            return total.map { Float($0 / Double(tokenCount)) }
        }
    }
}

@MainActor
final class SemanticIndex: ObservableObject {
    @Published private(set) var isBuilding = false
    @Published private(set) var keywordRevision = 0

    private let gate: NoteIndexGate
    private let worker: NoteIndexWorker
    private var buildGeneration = 0
    private var useAvailableKeywords = false

    init(directory: URL, debounce: Duration = .seconds(2),
         embedding: @escaping @Sendable () -> NoteIndexEmbedding? = NoteIndexEmbedding.localChinese) {
        let gate = NoteIndexGate(directory: directory)
        self.gate = gate
        worker = NoteIndexWorker(gate: gate, debounce: debounce, embedding: embedding)
    }

    func beginLibraryLoad() {
        buildGeneration += 1
        useAvailableKeywords = true
        if !isBuilding { isBuilding = true }
    }

    func finishLibraryLoadFailure() {
        buildGeneration += 1
        useAvailableKeywords = true
        isBuilding = false
    }

    /// Invalidate published tickets now. Model loading, reconciliation, and indexing run on the worker.
    func replaceLibrary(with snapshots: [NoteIndexSnapshot]) {
        beginLibraryLoad()
        let generation = buildGeneration
        let snapshots = snapshots.reduce(into: [UUID: NoteIndexSnapshot]()) { $0[$1.noteID] = $1 }
        let tickets = gate.replace(ids: Array(snapshots.keys))
        let notes = tickets.compactMap { ticket in
            snapshots[ticket.noteID].map { PendingIndexNote(snapshot: $0, ticket: ticket) }
        }
        worker.replace(notes, onKeywordsReady: { [weak self] in
            Task { @MainActor in
                guard let self, self.buildGeneration == generation, self.isBuilding else { return }
                self.keywordRevision += 1
            }
        }) { [weak self] in
            Task { @MainActor in
                guard let self, self.buildGeneration == generation else { return }
                self.useAvailableKeywords = false
                self.isBuilding = false
            }
        }
    }

    func apply(_ change: NoteIndexChange, immediately: Bool = false) throws {
        switch change {
        case .saved(let snapshot):
            let ticket = gate.issue(noteID: snapshot.noteID)
            worker.schedule(.init(snapshot: snapshot, ticket: ticket), immediately: immediately)
        case .removed(let noteID):
            defer { worker.remove(noteID) }
            try gate.remove(noteID)
        }
    }

    func search(_ query: String, limit: Int = 6, allowedNoteIDs: Set<UUID>? = nil) async -> NoteIndexSearchResult {
        let answer = await worker.search(query, limit: limit, allowedNoteIDs: allowedNoteIDs)
        return currentHits(in: answer)
    }

    /// Keep interactive retrieval independent of model loading and embedding work.
    func searchAvailable(
        _ query: String, limit: Int = 6, allowedNoteIDs: Set<UUID>? = nil
    ) async -> NoteIndexSearchResult {
        guard useAvailableKeywords else {
            return await search(query, limit: limit, allowedNoteIDs: allowedNoteIDs)
        }
        let answer = await worker.searchKeywords(query, limit: limit, allowedNoteIDs: allowedNoteIDs)
        return currentHits(in: answer)
    }

    private func currentHits(in answer: NoteIndexWorker.Answer) -> NoteIndexSearchResult {
        let current = gate.generations()
        return .init(mode: answer.result.mode, hits: answer.result.hits.filter { hit in
            let id = hit.chunk.noteID
            guard let generation = answer.generations[id] else { return false }
            return current[id] == generation
        })
    }

    /// Complete already queued work and index all pending snapshots without waiting for debounce.
    func flushPending() async { await worker.flushPending() }
}

private struct NoteIndexTicket: Sendable {
    let noteID: UUID
    let generation: UInt64
}

private struct PendingIndexNote: Sendable {
    let snapshot: NoteIndexSnapshot
    let ticket: NoteIndexTicket
}

/// Keep generations, published keyword entries and cache file names in sync.
private final class NoteIndexGate: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var latest: [UUID: UInt64] = [:]
    private var keywordEntries: [UUID: [SearchableNoteChunk]] = [:]
    private var nextGeneration: UInt64 = 0

    init(directory: URL) { self.directory = directory }

    func generations() -> [UUID: UInt64] { lock.withLock { latest } }

    func issue(noteID: UUID) -> NoteIndexTicket {
        lock.withLock { issueWhileLocked(noteID) }
    }

    func replace(ids: [UUID]) -> [NoteIndexTicket] {
        lock.withLock {
            latest.removeAll(keepingCapacity: true)
            keywordEntries.removeAll(keepingCapacity: true)
            return ids.map(issueWhileLocked)
        }
    }

    private func issueWhileLocked(_ id: UUID) -> NoteIndexTicket {
        nextGeneration += 1
        latest[id] = nextGeneration
        keywordEntries.removeValue(forKey: id)
        return .init(noteID: id, generation: nextGeneration)
    }

    func publishKeywords(_ chunks: [SearchableNoteChunk], for ticket: NoteIndexTicket) {
        lock.withLock {
            guard latest[ticket.noteID] == ticket.generation else { return }
            keywordEntries[ticket.noteID] = chunks
        }
    }

    func keywords(for ticket: NoteIndexTicket) -> [SearchableNoteChunk]? {
        lock.withLock {
            guard latest[ticket.noteID] == ticket.generation else { return nil }
            return keywordEntries[ticket.noteID]
        }
    }

    func keywordSnapshot() -> (entries: [UUID: [SearchableNoteChunk]], generations: [UUID: UInt64]) {
        lock.withLock { (keywordEntries, latest) }
    }

    func accepts(_ ticket: NoteIndexTicket) -> Bool {
        lock.withLock { latest[ticket.noteID] == ticket.generation }
    }

    func file(for noteID: UUID) -> URL { directory.appendingPathComponent(noteID.uuidString + ".qni") }

    private func partialFile(for noteID: UUID) -> URL {
        directory.appendingPathComponent(noteID.uuidString + ".qni-partial")
    }

    func remove(_ noteID: UUID) throws {
        try lock.withLock {
            latest.removeValue(forKey: noteID)
            keywordEntries.removeValue(forKey: noteID)
            var error: (any Error)?
            do { try unlinkIfPresent(partialFile(for: noteID)) } catch let failure { error = failure }
            do { try unlinkIfPresent(file(for: noteID)) } catch let failure { if error == nil { error = failure } }
            if let error { throw error }
        }
    }

    func purgeOrphans() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil) else { return }
        for url in files {
            if url.pathExtension == "qni-partial" {
                // This runs on the sole writer queue, so all staging files are left over from a previous process.
                try? unlinkIfPresent(url)
            } else if url.pathExtension == "qni", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                lock.withLock {
                    if latest[id] == nil { try? unlinkIfPresent(url) }
                }
            }
        }
    }

    func discard(_ ticket: NoteIndexTicket) {
        lock.withLock {
            if latest[ticket.noteID] == ticket.generation { try? unlinkIfPresent(file(for: ticket.noteID)) }
        }
    }

    func persist(_ data: Data, for ticket: NoteIndexTicket) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = partialFile(for: ticket.noteID)
        let handle: FileHandle? = try lock.withLock {
            guard latest[ticket.noteID] == ticket.generation else { return nil }
            // Open the file before releasing the lock. A concurrent removal can unlink it during the write.
            try unlinkIfPresent(partial)
            let fd = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw posixError() }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        guard let handle else { return }
        defer {
            try? handle.close()
            lock.withLock { try? unlinkIfPresent(partial) }
        }
        try handle.write(contentsOf: data)
        try lock.withLock {
            guard latest[ticket.noteID] == ticket.generation else { return }
            guard Darwin.rename(partial.path, file(for: ticket.noteID).path) == 0 else { throw posixError() }
        }
    }

    private func unlinkIfPresent(_ url: URL) throws {
        guard Darwin.unlink(url.path) != 0, errno != ENOENT else { return }
        throw posixError()
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

// The worker queue owns model loading and cache writes. Keyword preparation runs independently.
private final class NoteIndexWorker: @unchecked Sendable {
    struct Answer: Sendable {
        let result: NoteIndexSearchResult
        let generations: [UUID: UInt64]
    }

    private struct Entry {
        let generation: UInt64
        let chunks: [SearchableNoteChunk]
    }

    private struct Cache: Codable {
        static let currentVersion = 1
        let format: Int
        let fingerprint: String
        let model: NoteIndexModel
        let vectors: [[Float]]
    }

    private let queue = DispatchQueue(label: "QuickNote.SemanticIndex", qos: .userInitiated)
    private let keywordQueue = DispatchQueue(label: "QuickNote.SemanticIndex.Keywords", qos: .userInitiated)
    private let gate: NoteIndexGate
    private let debounceSeconds: Double
    private let embedding: @Sendable () -> NoteIndexEmbedding?
    private var model: NoteIndexEmbedding?
    private var modelResolved = false
    private var pending: [UUID: PendingIndexNote] = [:]
    private var entries: [UUID: Entry] = [:]

    init(gate: NoteIndexGate, debounce: Duration, embedding: @escaping @Sendable () -> NoteIndexEmbedding?) {
        self.gate = gate
        let parts = debounce.components
        debounceSeconds = max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        self.embedding = embedding
    }

    func replace(_ notes: [PendingIndexNote], onKeywordsReady: @escaping @Sendable () -> Void,
                 onComplete: @escaping @Sendable () -> Void) {
        keywordQueue.async { [self] in
            for note in notes { prepareKeywords(note) }
            onKeywordsReady()
        }
        queue.async { [self] in
            defer { onComplete() }
            entries.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            model = embedding()
            modelResolved = true
            gate.purgeOrphans()
            for note in notes { index(note) }
        }
    }

    func schedule(_ note: PendingIndexNote, immediately: Bool) {
        keywordQueue.async { [self] in prepareKeywords(note) }
        queue.async { [self] in
            guard gate.accepts(note.ticket) else { return }
            let id = note.ticket.noteID
            if immediately || debounceSeconds == 0 {
                pending.removeValue(forKey: id)
                index(note)
            } else {
                pending[id] = note
                let generation = note.ticket.generation
                queue.asyncAfter(deadline: .now() + debounceSeconds) { [weak self] in
                    guard let self, let note = pending[id], note.ticket.generation == generation else { return }
                    pending.removeValue(forKey: id)
                    index(note)
                }
            }
        }
    }

    func remove(_ id: UUID) {
        queue.async { [self] in
            pending.removeValue(forKey: id)
            entries.removeValue(forKey: id)
        }
    }

    func flushPending() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let notes = pending.values.sorted { $0.ticket.generation < $1.ticket.generation }
                pending.removeAll(keepingCapacity: true)
                for note in notes { index(note) }
                continuation.resume()
            }
        }
    }

    func search(_ query: String, limit: Int, allowedNoteIDs: Set<UUID>?) async -> Answer {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                resolveModel()
                let current = gate.generations()
                let chunks = entries.flatMap { id, entry in
                    guard allowedNoteIDs?.contains(id) != false, current[id] == entry.generation else {
                        return [SearchableNoteChunk]()
                    }
                    return entry.chunks
                }
                let queryVector: [Float]?
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let model {
                    queryVector = HybridSearchRanking.normalized(model.vector(query), dimension: model.model.dimension)
                } else {
                    queryVector = nil
                }
                var result = HybridSearchRanking.search(query, chunks: chunks, queryVector: queryVector, limit: limit)
                if chunks.isEmpty, model != nil {
                    result = .init(mode: .hybrid, hits: [])
                }
                continuation.resume(returning: Answer(result: result, generations: current))
            }
        }
    }

    func searchKeywords(_ query: String, limit: Int, allowedNoteIDs: Set<UUID>?) async -> Answer {
        let snapshot = gate.keywordSnapshot()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let chunks = snapshot.entries.flatMap { id, chunks in
                    allowedNoteIDs?.contains(id) == false ? [] : chunks
                }
                let result = HybridSearchRanking.search(query, chunks: chunks, queryVector: nil, limit: limit)
                continuation.resume(returning: Answer(result: result, generations: snapshot.generations))
            }
        }
    }

    private func resolveModel() {
        guard !modelResolved else { return }
        model = embedding()
        modelResolved = true
    }

    private func prepareKeywords(_ note: PendingIndexNote) {
        guard gate.accepts(note.ticket) else { return }
        let chunks = NoteChunker.chunks(for: note.snapshot).map { SearchableNoteChunk(chunk: $0, vector: nil) }
        gate.publishKeywords(chunks, for: note.ticket)
    }

    private func index(_ note: PendingIndexNote) {
        guard gate.accepts(note.ticket) else { return }
        guard let keywords = keywordQueue.sync(execute: { gate.keywords(for: note.ticket) }) else { return }
        resolveModel()
        let vectors = buildVectors(for: note, chunks: keywords.map(\.chunk))
        let indexed = zip(keywords, vectors).map { lexical, vector in
            guard let vector else { return lexical }
            return SearchableNoteChunk(chunk: lexical.chunk, vector: vector)
        }
        guard gate.accepts(note.ticket) else { return }
        entries[note.ticket.noteID] = Entry(generation: note.ticket.generation, chunks: indexed)
    }

    private func buildVectors(for note: PendingIndexNote, chunks: [NoteIndexChunk]) -> [[Float]?] {
        guard let model, let fingerprint = chunks.first?.sourceFingerprint else {
            gate.discard(note.ticket)
            return Array(repeating: nil, count: chunks.count)
        }
        // Persist only model metadata, source fingerprint and vectors. Excerpts and citation ranges
        // always come from the current eligible snapshot, never from cached bytes.
        let url = gate.file(for: note.ticket.noteID)
        if let data = try? Data(contentsOf: url),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.format == Cache.currentVersion, cache.fingerprint == fingerprint, cache.model == model.model,
           cache.vectors.count == chunks.count {
            let checked = cache.vectors.map { HybridSearchRanking.normalized($0, dimension: model.model.dimension) }
            if checked.allSatisfy({ $0 != nil }) { return checked }
        }

        var vectors: [[Float]?] = []
        for chunk in chunks {
            guard gate.accepts(note.ticket) else { return Array(repeating: nil, count: chunks.count) }
            vectors.append(HybridSearchRanking.normalized(model.vector(chunk.text), dimension: model.model.dimension))
        }
        let complete = vectors.compactMap { $0 }
        if complete.count == chunks.count {
            let cache = Cache(format: Cache.currentVersion, fingerprint: fingerprint, model: model.model, vectors: complete)
            if let data = try? JSONEncoder().encode(cache) { try? gate.persist(data, for: note.ticket) }
        } else {
            gate.discard(note.ticket)
        }
        return vectors
    }
}

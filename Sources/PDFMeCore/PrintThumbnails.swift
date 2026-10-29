import Foundation
import PDFKit
import CoreGraphics

/// Identifies exactly what a thumbnail shows. Identical sides, such as repeated copies, share one
/// image, and a changed range, PDF, or layout always gets a new key instead of an old image.
public struct PrintThumbnailKey: Hashable, Sendable {
    public struct Page: Hashable, Sendable {
        /// The reviewed input, so a re-added file with the same path renders again.
        public let document: UUID
        public let url: URL
        public let page: Int
    }
    public let pages: [Page]
    public let paper: PrintPaper
    public let orientation: PrintOrientation
    public let pagesPerSide: Int
    public let grayscale: Bool
    public init?(side: [PrintPageReference], inputs: [PrintInput], template: PrintTemplate) {
        guard side.allSatisfy({ inputs.indices.contains($0.document) }) else { return nil }
        pages = side.map { Page(document: inputs[$0.document].id, url: inputs[$0.document].url, page: $0.page) }
        paper = template.paper; orientation = template.orientation
        pagesPerSide = template.pagesPerSide; grayscale = template.color == .grayscale
    }
    /// Only the settings that change the composed side. Image resolution does not apply at thumbnail size.
    public var template: PrintTemplate {
        PrintTemplate(paper: paper, orientation: orientation, pagesPerSide: pagesPerSide, color: grayscale ? .grayscale : .color)
    }
}

/// Opens each PDF once for consecutive thumbnails. The store runs one render at a time.
final class PrintThumbnailRenderer: @unchecked Sendable {
    private struct Source: Hashable { let document: UUID; let url: URL }
    private let lock = NSLock()
    private var open: [(source: Source, document: PDFDocument)] = []
    private let documentLimit = 4

    func render(_ key: PrintThumbnailKey, maxPixelSize: Int) throws -> CGImage {
        var documents: [Int: PDFDocument] = [:], indices: [Source: Int] = [:], side: [PrintPageReference] = []
        for page in key.pages {
            let source = Source(document: page.document, url: page.url)
            let index: Int
            if let existing = indices[source] { index = existing } else {
                index = indices.count; indices[source] = index
                documents[index] = try document(source)
            }
            side.append(PrintPageReference(document: index, page: page.page))
        }
        return try PrintComposer.thumbnail(of: side, documents: documents, template: key.template, maxPixelSize: maxPixelSize)
    }
    private func document(_ source: Source) throws -> PDFDocument {
        lock.lock()
        if let index = open.firstIndex(where: { $0.source == source }) {
            let entry = open.remove(at: index); open.append(entry); lock.unlock()
            return entry.document
        }
        lock.unlock()
        try Task.checkCancellation()
        guard let document = PDFDocument(url: source.url), !document.isLocked, document.allowsPrinting else {
            throw PrintError.message("Couldn’t open \(source.url.lastPathComponent) for preview.")
        }
        lock.lock(); defer { lock.unlock() }
        open.append((source, document))
        if open.count > documentLimit { open.removeFirst(open.count - documentLimit) }
        return document
    }
    func retain(_ live: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        open.removeAll { !live.contains($0.source.document) }
    }
}

/// Small preview images for one print model, shared by every preview surface showing it.
/// Cells request images while visible; requests for the same side are combined, renders run one
/// at a time with the newest request first, and cells that disappear cancel their work.
@MainActor
public final class PrintThumbnailStore {
    public static let maxPixelSize = 300
    public typealias Render = @Sendable (PrintThumbnailKey) throws -> CGImage
    public struct Limits: Sendable {
        public var count: Int, bytes: Int, pending: Int, failures: Int
        public init(count: Int = 160, bytes: Int = 24 << 20, pending: Int = 48, failures: Int = 64) {
            self.count = max(1, count); self.bytes = bytes; self.pending = max(1, pending); self.failures = failures
        }
    }
    private struct Entry { let image: CGImage; let bytes: Int; var used: UInt64 }
    private final class Request { var waiters: [UUID: CheckedContinuation<Result<CGImage, PrintError>?, Never>] = [:]; var started = false }

    public let limits: Limits
    private let render: Render
    private let renderer: PrintThumbnailRenderer?
    private var cache: [PrintThumbnailKey: Entry] = [:]
    private var failures: [PrintThumbnailKey: String] = [:]
    private var requests: [PrintThumbnailKey: Request] = [:]
    /// Not started yet; the newest is rendered first so the cells the user just scrolled to win.
    private var pending: [PrintThumbnailKey] = []
    private var running: (key: PrintThumbnailKey, task: Task<CGImage, Error>)?
    private var live: Set<UUID>?
    private var clock: UInt64 = 0

    public private(set) var cachedBytes = 0
    public private(set) var renderCount = 0
    public var cachedCount: Int { cache.count }
    public var pendingCount: Int { pending.count }
    public var waiterCount: Int { requests.values.reduce(0) { $0 + $1.waiters.count } }
    public var isRendering: Bool { running != nil }

    /// `render` is a test seam; it runs off the main actor.
    public init(limits: Limits = Limits(), render: Render? = nil) {
        self.limits = limits
        if let render { self.render = render; renderer = nil } else {
            let renderer = PrintThumbnailRenderer(), size = Self.maxPixelSize
            self.renderer = renderer
            self.render = { try renderer.render($0, maxPixelSize: size) }
        }
    }

    /// A cached image without changing its eviction order, for drawing a cell immediately.
    public func peek(_ key: PrintThumbnailKey) -> CGImage? { cache[key]?.image }
    public func failure(for key: PrintThumbnailKey) -> String? { failures[key] }

    /// Returns nil when the request was cancelled, dropped, or its PDF was removed.
    public func image(for key: PrintThumbnailKey) async -> Result<CGImage, PrintError>? {
        if let entry = cache[key] { clock += 1; cache[key]?.used = clock; return .success(entry.image) }
        if let failure = failures[key] { return .failure(.message(failure)) }
        guard isLive(key) else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                enqueue(key, waiter: id, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(waiter: id, for: key) }
        }
    }

    /// Call when the batch's documents change. Images of remaining PDFs stay cached, so moving
    /// between sides or toggling the grid never re-renders them.
    public func retain(documents: Set<UUID>) {
        guard live != documents else { return }
        live = documents
        cache = cache.filter { isLive($0.key) }
        cachedBytes = cache.values.reduce(0) { $0 + $1.bytes }
        failures.removeAll()
        for key in pending where !isLive(key) { drop(key) }
        pending.removeAll { !isLive($0) }
        if let running, !isLive(running.key) { drop(running.key); running.task.cancel() }
        renderer?.retain(documents)
    }
    /// Every preview surface closed. Cached images remain for when it reopens.
    public func cancelAll() {
        for key in pending { drop(key) }
        pending.removeAll()
        if let running { drop(running.key); running.task.cancel() }
    }

    private func isLive(_ key: PrintThumbnailKey) -> Bool {
        guard let live else { return true }
        return key.pages.allSatisfy { live.contains($0.document) }
    }
    private func enqueue(_ key: PrintThumbnailKey, waiter: UUID, _ continuation: CheckedContinuation<Result<CGImage, PrintError>?, Never>) {
        if let request = requests[key] {
            request.waiters[waiter] = continuation
            if !request.started, let index = pending.firstIndex(of: key) { pending.remove(at: index); pending.append(key) }
        } else {
            let request = Request(); request.waiters[waiter] = continuation
            requests[key] = request; pending.append(key)
            while pending.count > limits.pending { drop(pending.removeFirst()) }
        }
        pump()
    }
    /// Resume every waiter without an image; their cells try again if they are still visible.
    private func drop(_ key: PrintThumbnailKey) {
        guard let request = requests.removeValue(forKey: key) else { return }
        for continuation in request.waiters.values { continuation.resume(returning: nil) }
    }
    private func cancel(waiter: UUID, for key: PrintThumbnailKey) {
        guard let request = requests[key], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        guard request.waiters.isEmpty else { return }
        if request.started { running?.task.cancel() }
        else { requests[key] = nil; pending.removeAll { $0 == key } }
    }
    private func pump() {
        while running == nil, let key = pending.popLast() {
            guard let request = requests[key] else { continue }
            if let entry = cache[key] {
                requests[key] = nil
                for continuation in request.waiters.values { continuation.resume(returning: .success(entry.image)) }
                continue
            }
            request.started = true
            let render = render
            let task = Task.detached(priority: .utility) { try render(key) }
            running = (key, task); renderCount += 1
            Task { [weak self] in
                let result = await task.result
                self?.finish(key, result, cancelled: task.isCancelled)
            }
        }
    }
    private func finish(_ key: PrintThumbnailKey, _ result: Result<CGImage, Error>, cancelled: Bool) {
        running = nil
        defer { pump() }
        if case .success(let image) = result, isLive(key) { insert(image, for: key) }
        // A request that was dropped, or replaced by one that hasn't started, has nobody waiting here.
        guard let request = requests[key], request.started else { return }
        switch result {
        case .success(let image):
            requests[key] = nil
            for continuation in request.waiters.values { continuation.resume(returning: .success(image)) }
        case .failure(let error) where cancelled || error is CancellationError:
            // Someone asked again while the cancelled render was finishing.
            if request.waiters.isEmpty || !isLive(key) { drop(key) } else { request.started = false; pending.append(key) }
        case .failure(let error):
            requests[key] = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if isLive(key) {
                if failures.count >= limits.failures, let old = failures.keys.first { failures[old] = nil }
                failures[key] = message
            }
            for continuation in request.waiters.values { continuation.resume(returning: .failure(.message(message))) }
        }
    }
    private func insert(_ image: CGImage, for key: PrintThumbnailKey) {
        clock += 1
        let bytes = image.bytesPerRow * image.height
        if let old = cache[key] { cachedBytes -= old.bytes }
        cache[key] = Entry(image: image, bytes: bytes, used: clock); cachedBytes += bytes
        while cache.count > 1 && (cache.count > limits.count || cachedBytes > limits.bytes),
              let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key {
            cachedBytes -= cache.removeValue(forKey: oldest)?.bytes ?? 0
        }
    }
}

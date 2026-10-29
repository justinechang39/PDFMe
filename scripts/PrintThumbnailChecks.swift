import AppKit
import Foundation
import PDFKit
import PDFMeCore

/// Thread-safe log for the fake renderer used by the store checks.
final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0, open = true
    private(set) var peak = 0
    private(set) var order: [Int] = []
    private(set) var failing: Set<Int> = []
    func setOpen(_ value: Bool) { lock.lock(); open = value; lock.unlock() }
    func fail(_ page: Int) { lock.lock(); failing.insert(page); lock.unlock() }
    var rendered: [Int] { lock.lock(); defer { lock.unlock() }; return order }
    /// Waits while the gate is closed so tests can queue work behind a running render.
    func render(_ key: PrintThumbnailKey, ignoreCancel: Bool = false) throws -> CGImage {
        lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        while true {
            if !ignoreCancel { try Task.checkCancellation() }
            lock.lock(); let go = open; lock.unlock()
            if go { break }
            Thread.sleep(forTimeInterval: 0.003)
        }
        Thread.sleep(forTimeInterval: 0.005)
        let page = key.pages.first?.page ?? -1
        lock.lock(); order.append(page); let fails = failing.contains(page); lock.unlock()
        if fails { throw PrintError.message("Fixture render failure \(page)") }
        return Self.image()
    }
    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }
}

@main
struct PrintThumbnailChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PrintError.message("FAIL: " + message) }
        print("PASS: " + message)
    }

    // MARK: Pixels

    struct Raster { let width: Int, height: Int, gray: Bool, bytes: [UInt8] }
    static func raster(width: Int, height: Int, gray: Bool, _ draw: (CGContext) -> Void) -> Raster {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * (gray ? 1 : 4),
                                space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        let count = width * height * (gray ? 1 : 4)
        return Raster(width: width, height: height, gray: gray, bytes: Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: count)))
    }
    /// The prepared side drawn at exactly the thumbnail's pixel size and color space.
    static func raster(_ page: PDFPage, like image: CGImage, gray: Bool) -> Raster {
        raster(width: image.width, height: image.height, gray: gray) { context in
            let media = page.bounds(for: .mediaBox)
            context.scaleBy(x: CGFloat(image.width) / media.width, y: CGFloat(image.height) / media.height)
            context.translateBy(x: -media.minX, y: -media.minY)
            context.interpolationQuality = .high
            context.drawPDFPage(page.pageRef!)
        }
    }
    static func raster(_ image: CGImage, gray: Bool) -> Raster {
        raster(width: image.width, height: image.height, gray: gray) { $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) }
    }
    /// Mean channel difference and the fraction of pixels differing by more than 64 in any channel.
    static func difference(_ a: Raster, _ b: Raster) -> (mean: Double, bad: Double) {
        precondition(a.bytes.count == b.bytes.count)
        let stride = a.gray ? 1 : 4, channels = a.gray ? 1 : 3
        var total = 0, bad = 0
        for pixel in 0..<(a.width * a.height) {
            var worst = 0
            for channel in 0..<channels {
                let d = abs(Int(a.bytes[pixel * stride + channel]) - Int(b.bytes[pixel * stride + channel]))
                total += d; worst = max(worst, d)
            }
            if worst > 64 { bad += 1 }
        }
        return (Double(total) / Double(a.width * a.height * channels), Double(bad) / Double(a.width * a.height))
    }
    static func count(_ r: Raster, _ match: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        (0..<(r.width * r.height)).reduce(0) { $0 + (match(r.bytes[$1 * 4], r.bytes[$1 * 4 + 1], r.bytes[$1 * 4 + 2]) ? 1 : 0) }
    }

    @MainActor
    static func compareAll(_ name: String, inputs: [PrintInput], template: PrintTemplate, root: URL, mean: Double, bad: Double) async throws -> (PrintPlan, PDFDocument, [CGImage]) {
        let output = root.appendingPathComponent("Thumbnail \(name).pdf")
        let plan = try PrintComposer.prepare(inputs: inputs, template: template, output: output)
        let prepared = PDFDocument(url: output)!
        let store = PrintThumbnailStore()
        let gray = template.color == .grayscale
        var images: [CGImage] = [], worst = (mean: 0.0, bad: 0.0), nearest = Double.infinity
        var sides: [Raster] = []
        for (index, side) in plan.sides.enumerated() {
            let key = PrintThumbnailKey(side: side, inputs: inputs, template: template)!
            guard case .success(let image)? = await store.image(for: key) else { throw PrintError.message("FAIL: \(name) side \(index + 1) thumbnail did not render") }
            try check(max(image.width, image.height) == PrintThumbnailStore.maxPixelSize && (image.colorSpace?.model == (gray ? .monochrome : .rgb)),
                      "\(name) side \(index + 1) is a \(image.width)×\(image.height) \(gray ? "grayscale" : "color") bitmap")
            if sides.isEmpty { sides = (0..<prepared.pageCount).map { raster(prepared.page(at: $0)!, like: image, gray: gray) } }
            let thumbnail = raster(image, gray: gray)
            let d = difference(thumbnail, sides[index])
            if d.mean > mean || d.bad > bad {
                let expected = sides[index]
                let provider = CGDataProvider(data: Data(expected.bytes) as CFData)!
                let reference = CGImage(width: expected.width, height: expected.height, bitsPerComponent: 8, bitsPerPixel: gray ? 8 : 32,
                    bytesPerRow: expected.width * (gray ? 1 : 4), space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Mismatch thumbnail \(index).png"))
                try NSBitmapImageRep(cgImage: reference).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Mismatch prepared \(index).png"))
            }
            worst = (max(worst.mean, d.mean), max(worst.bad, d.bad))
            // The metric must tell different sides apart, or matching proves nothing.
            for other in plan.sides.indices where plan.sides[other] != side && !(plan.sides[other].isEmpty || side.isEmpty) {
                nearest = min(nearest, difference(thumbnail, sides[other]).bad)
            }
            images.append(image)
        }
        try check(prepared.pageCount == plan.sides.count, "\(name): prepared output has every planned side")
        print(String(format: "  %@: worst mean %.3f, worst bad %.4f%%, nearest different side bad %.4f%%", name, worst.mean, worst.bad * 100, nearest * 100))
        try check(worst.mean <= mean && worst.bad <= bad, "\(name): every thumbnail matches its prepared side (\(plan.sides.count) sides)")
        if nearest.isFinite { try check(nearest > worst.bad * 4 && nearest > 0.002, "\(name): comparison distinguishes different sides") }
        return (plan, prepared, images)
    }

    /// Give each fixture page a large unique binary marker. Tiny page-number text alone
    /// vanishes at thumbnail scale, so it cannot prove that a thumbnail shows the right side.
    static func marked(_ source: URL, seed: Int) throws -> URL {
        let pdf = PDFDocument(url: source)!
        for index in 0..<pdf.pageCount {
            for bit in 0..<6 where ((seed + index) >> bit) & 1 == 1 {
                let marker = PDFAnnotation(bounds: CGRect(x: 40 + bit * 80, y: 120, width: 60, height: 120), forType: .square, withProperties: nil)
                marker.color = .black; marker.interiorColor = .black; marker.shouldPrint = true
                pdf.page(at: index)!.addAnnotation(marker)
            }
        }
        let output = source.deletingLastPathComponent().appendingPathComponent("Thumbnail marked " + source.lastPathComponent)
        guard pdf.write(to: output) else { throw PrintError.message("Could not save marked fixture") }
        return output
    }

    @MainActor
    static func pixelChecks(root: URL) async throws {
        let a = try marked(root.appendingPathComponent("01 Sample A.pdf"), seed: 1)
        let b = try marked(root.appendingPathComponent("02 Sample B.pdf"), seed: 34)
        let c = try marked(root.appendingPathComponent("03 Sample C.pdf"), seed: 4)
        let rotated = root.appendingPathComponent("Rotated crop.pdf")

        // Ranges, n-up, copies, duplex blank backs, and a shared document order.
        var ranged = try PrintComposer.inspect([a, c, b])
        ranged[0].pageSelection = .custom("3, 1"); ranged[0].copies = 2
        ranged[1].pageSelection = .custom("1-3, 21-22, 2, 29-end")
        ranged[2].pageSelection = .custom("2")
        let duplex = PrintTemplate(orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2, printAsImage: false)
        let (plan, _, images) = try await compareAll("ranges 2-up duplex copies", inputs: ranged, template: duplex, root: root, mean: 0.5, bad: 0.001)
        let blank = raster(images[1], gray: false)
        try check(plan.sides[1].isEmpty && blank.bytes.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 255 }, "blank duplex back thumbnail is plain white")

        // Grayscale image printing with 4-up, a rotated page, and a cropped page.
        var mixed = try PrintComposer.inspect([a, rotated])
        mixed[0].pageSelection = .custom("2-end")
        let gray = PrintTemplate(duplex: .longEdge, pagesPerSide: 4, printAsImage: true, dpi: 150, color: .grayscale, startEachFileOnNewSheet: false)
        _ = try await compareAll("grayscale image 4-up rotated crop", inputs: mixed, template: gray, root: root, mean: 3, bad: 0.01)

        // Printable and non-printing annotations with a 270° page rotation.
        let annotated = root.appendingPathComponent("Annotated rotated.pdf")
        let source = PDFDocument(url: a)!
        let printed = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 200, height: 150), forType: .square, withProperties: nil)
        printed.color = .red; printed.interiorColor = .red; printed.shouldPrint = true
        let screenOnly = PDFAnnotation(bounds: CGRect(x: 60, y: 300, width: 200, height: 150), forType: .square, withProperties: nil)
        screenOnly.color = .blue; screenOnly.interiorColor = .blue; screenOnly.shouldPrint = false
        source.page(at: 1)!.addAnnotation(printed); source.page(at: 1)!.addAnnotation(screenOnly)
        source.page(at: 2)!.rotation = 270
        try check(source.write(to: annotated), "write annotation and rotation fixture")
        let fixture = try PrintComposer.inspect([annotated])
        let single = PrintTemplate(printAsImage: false)
        let (_, prepared, singles) = try await compareAll("annotations rotation 1-up", inputs: fixture, template: single, root: root, mean: 0.5, bad: 0.001)
        let thumb = raster(singles[1], gray: false), printedSide = raster(prepared.page(at: 1)!, like: singles[1], gray: false)
        let red: (UInt8, UInt8, UInt8) -> Bool = { $0 > 200 && $1 < 80 && $2 < 80 }, blue: (UInt8, UInt8, UInt8) -> Bool = { $2 > 200 && $0 < 80 && $1 < 80 }
        try check(count(thumb, red) > 500 && count(printedSide, red) > 500, "printable annotation appears in the thumbnail and prepared output")
        try check(count(thumb, blue) == 0 && count(printedSide, blue) == 0, "non-printing annotation is omitted in both")
        // The 300-dpi print raster is resampled here; measured edge-only differences are
        // about 1.2% of pixels, versus >22% for the wrong side. Keep the mean limit strict.
        _ = try await compareAll("annotations rotation 2-up image", inputs: fixture, template: PrintTemplate(orientation: .landscape, pagesPerSide: 2, printAsImage: true, dpi: 300), root: root, mean: 3, bad: 0.02)

        // Thumbnails never use the print raster: A3 at 600 dpi still renders a 300 px bitmap quickly.
        let large = PrintTemplate(paper: .a3, printAsImage: true, dpi: 600)
        let documents = [0: PDFDocument(url: c)!]
        let started = Date()
        for page in 0..<30 { _ = try PrintComposer.thumbnail(of: side(page), documents: documents, template: large, maxPixelSize: 300) }
        let perThumb = Date().timeIntervalSince(started) / 30
        let printStarted = Date()
        _ = try PrintComposer.previewSide(urls: [c], side: side(0), template: large)
        let printSide = Date().timeIntervalSince(printStarted)
        print(String(format: "  thumbnail %.1f ms each; one 600 dpi A3 preview side %.1f ms", perThumb * 1000, printSide * 1000))
        try check(perThumb * 5 < printSide, "thumbnail rendering is far cheaper than the print-resolution raster")
        let image = try PrintComposer.thumbnail(of: [], documents: [:], template: large, maxPixelSize: 300)
        try check(image.height == 300 && image.width == 212, "A3 thumbnail is bounded to 300 px")
        for bad in [8, 5000] {
            do { _ = try PrintComposer.thumbnail(of: [], documents: [:], template: large, maxPixelSize: bad); throw PrintError.message("FAIL: accepted \(bad) px") }
            catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL"), "rejects thumbnail size \(bad) px") }
        }
    }

    // MARK: Store

    /// One page of the first document on a side.
    static func side(_ page: Int) -> [PrintPageReference] { try! PrintPlan(pages: [[page]], template: PrintTemplate()).sides[0] }
    static func key(_ page: Int, _ input: PrintInput, grayscale: Bool = false) -> PrintThumbnailKey {
        PrintThumbnailKey(side: side(page), inputs: [input], template: PrintTemplate(color: grayscale ? .grayscale : .color))!
    }
    @MainActor
    static func settle(_ store: PrintThumbnailStore, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 4_000_000) }
        guard condition() else { throw PrintError.message("FAIL: timed out waiting for the thumbnail store") }
    }

    @MainActor
    static func storeChecks() async throws {
        let x = PrintInput(url: URL(fileURLWithPath: "/tmp/x.pdf"), pages: 400)
        let y = PrintInput(url: URL(fileURLWithPath: "/tmp/y.pdf"), pages: 400)
        try check(key(1, x) == key(1, x) && key(1, x) != key(2, x) && key(1, x) != key(1, y) && key(1, x) != key(1, x, grayscale: true),
                  "keys identify pages, documents, and layout")
        let reAdded = PrintInput(url: x.url, pages: 400)
        try check(key(1, x) != key(1, reAdded), "a re-added file with the same path gets new thumbnails")
        let copies = try PrintPlan(inputs: [PrintInput(url: x.url, pages: 3, id: x.id, copies: 3)], template: PrintTemplate())
        let copyKeys = copies.sides.map { PrintThumbnailKey(side: $0, inputs: [PrintInput(url: x.url, pages: 3, id: x.id)], template: PrintTemplate())! }
        try check(copies.sides.count == 9 && Set(copyKeys).count == 3, "repeated copies share thumbnails (9 sides, 3 images)")

        // Combined and serial work, newest request first.
        let probe = RenderProbe()
        let store = PrintThumbnailStore(limits: .init(count: 5, bytes: 1 << 20, pending: 4)) { try probe.render($0) }
        probe.setOpen(false)
        let first = Task { await store.image(for: key(0, x)) }
        try await settle(store) { store.isRendering }
        let duplicate = Task { await store.image(for: key(0, x)) }
        var queued: [Task<Result<CGImage, PrintError>?, Never>] = []
        for page in 1...7 {
            queued.append(Task { await store.image(for: key(page, x)) })
            for _ in 0..<5 { await Task.yield() }
        }
        try check(store.pendingCount == 4, "pending work is bounded (\(store.pendingCount) of 7 queued)")
        for dropped in queued.prefix(3) { let value = await dropped.value; try check(value == nil, "oldest queued request is dropped, not rendered") }
        probe.setOpen(true)
        let a = await first.value, b = await duplicate.value
        if case .success(let one)? = a, case .success(let two)? = b { try check(one === two, "identical concurrent requests share one image") }
        else { throw PrintError.message("FAIL: shared request failed") }
        for task in queued.suffix(4) { _ = await task.value }
        try await settle(store) { !store.isRendering && store.pendingCount == 0 }
        try check(probe.rendered == [0, 7, 6, 5, 4], "renders newest requests first, once each: \(probe.rendered)")
        try check(probe.peak == 1 && store.renderCount == 5, "only one thumbnail renders at a time")
        try check(store.cachedCount == 5, "cache holds rendered images")

        // Bounded cache with least-recently used eviction.
        _ = await store.image(for: key(0, x))
        for page in 20..<24 { _ = await store.image(for: key(page, x)) }
        try check(store.cachedCount == 5 && store.peek(key(0, x)) != nil && store.peek(key(7, x)) == nil && store.peek(key(4, x)) == nil,
                  "cache count is bounded and evicts the least recently used")
        for page in 24..<26 { _ = await store.image(for: key(page, x)) }
        try check(store.cachedCount == 5 && store.peek(key(0, x)) == nil && store.peek(key(25, x)) != nil, "older images leave as new sides render")
        let each = RenderProbe.image().bytesPerRow * RenderProbe.image().height
        let tight = PrintThumbnailStore(limits: .init(count: 100, bytes: each * 3 + each / 2)) { try probe.render($0) }
        for page in 0..<10 { _ = await tight.image(for: key(page, x)) }
        try check(tight.cachedBytes <= each * 3 + each / 2 && tight.cachedCount == 3, "cache bytes are bounded (\(tight.cachedBytes) bytes, \(tight.cachedCount) images)")
        let before = store.renderCount
        _ = await store.image(for: key(25, x))
        try check(store.renderCount == before, "cached thumbnails are reused without rendering")

        // Cancelling cells that disappeared.
        let cancelProbe = RenderProbe()
        let cancels = PrintThumbnailStore() { try cancelProbe.render($0) }
        cancelProbe.setOpen(false)
        let running = Task { await cancels.image(for: key(1, x)) }
        try await settle(cancels) { cancels.isRendering }
        let waiting = Task { await cancels.image(for: key(2, x)) }
        let kept = Task { await cancels.image(for: key(3, x)) }
        try await settle(cancels) { cancels.pendingCount == 2 }
        waiting.cancel()
        let waited = await waiting.value
        try check(waited == nil, "cancelled cell gets no image")
        try await settle(cancels) { cancels.pendingCount == 1 }
        running.cancel()
        let ran = await running.value
        try check(ran == nil, "cancelling the running cell stops waiting")
        try await settle(cancels) { cancels.isRendering && cancelProbe.rendered.isEmpty && cancels.peek(key(1, x)) == nil }
        cancelProbe.setOpen(true)
        _ = await kept.value
        try await settle(cancels) { !cancels.isRendering }
        try check(cancelProbe.rendered == [3] && cancels.peek(key(1, x)) == nil && cancels.peek(key(2, x)) == nil, "cancelled requests never render or cache")
        cancelProbe.setOpen(false)
        let again = Task { await cancels.image(for: key(4, x)) }
        try await settle(cancels) { cancels.isRendering }
        again.cancel(); _ = await again.value
        let rejoined = Task { await cancels.image(for: key(4, x)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelProbe.setOpen(true)
        if case .success? = await rejoined.value {} else { throw PrintError.message("FAIL: rejoined request after cancellation") }
        try check(cancels.peek(key(4, x)) != nil, "a cell that returns during cancellation still gets its image")

        // Content changes: removed PDFs drop images, failures, queued and in-flight results.
        let staleProbe = RenderProbe()
        let content = PrintThumbnailStore() { try staleProbe.render($0, ignoreCancel: true) }
        content.retain(documents: [x.id, y.id])
        _ = await content.image(for: key(1, x)); _ = await content.image(for: key(1, y))
        staleProbe.fail(9)
        let failed = await content.image(for: key(9, y))
        let renders = content.renderCount
        let failedAgain = await content.image(for: key(9, y))
        if case .failure? = failed, case .failure? = failedAgain {
            try check(content.renderCount == renders && content.failure(for: key(9, y)) != nil, "a failed side shows its error without retrying on every scroll")
        } else { throw PrintError.message("FAIL: failure was not reported") }
        staleProbe.setOpen(false)
        let inFlight = Task { await content.image(for: key(2, y)) }
        try await settle(content) { content.isRendering }
        let queuedForRemoved = Task { await content.image(for: key(3, y)) }
        try await settle(content) { content.pendingCount == 1 }
        content.retain(documents: [x.id])
        let removedResult = await queuedForRemoved.value
        try check(removedResult == nil && content.pendingCount == 0, "queued work for a removed PDF is dropped")
        staleProbe.setOpen(true)
        _ = await inFlight.value
        try await settle(content) { !content.isRendering }
        try check(content.peek(key(2, y)) == nil && content.peek(key(1, y)) == nil && content.peek(key(1, x)) != nil, "a render finishing after its PDF was removed is not cached; others stay")
        let removedRequest = await content.image(for: key(5, y))
        try check(removedRequest == nil && content.failure(for: key(9, y)) == nil, "removed PDFs cannot be requested and their errors are cleared")

        // Closing every preview surface.
        let closing = RenderProbe(); closing.setOpen(false)
        let hidden = PrintThumbnailStore() { try closing.render($0) }
        let hiddenRunning = Task { await hidden.image(for: key(1, x)) }
        try await settle(hidden) { hidden.isRendering }
        let hiddenQueued = Task { await hidden.image(for: key(2, x)) }
        try await settle(hidden) { hidden.pendingCount == 1 }
        hidden.cancelAll()
        let hiddenResult = await hiddenQueued.value
        try check(hiddenResult == nil, "closing the preview drops queued thumbnails")
        try await settle(hidden) { !hidden.isRendering }
        _ = await hiddenRunning.value
        try check(closing.rendered.isEmpty && hidden.pendingCount == 0 && hidden.waiterCount == 0, "closing the preview cancels the running thumbnail")
    }

    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await pixelChecks(root: root)
        try await storeChecks()
        print("All thumbnail checks passed. No print jobs submitted.")
    }
}

import Foundation
import PDFKit
import CoreGraphics
import Darwin

public enum PrintPaper: String, Codable, CaseIterable, Sendable {
    case a4 = "A4", letter = "Letter", a5 = "A5", legal = "Legal", a3 = "A3"
    public var size: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.276, height: 841.890)
        case .letter: return CGSize(width: 612, height: 792)
        case .a5: return CGSize(width: 419.528, height: 595.276)
        case .legal: return CGSize(width: 612, height: 1008)
        case .a3: return CGSize(width: 841.890, height: 1190.551)
        }
    }
}
public enum PrintOrientation: String, Codable, CaseIterable, Sendable { case portrait = "Portrait", landscape = "Landscape" }
public enum PrintDuplex: String, Codable, CaseIterable, Sendable {
    case off = "One-sided", longEdge = "Duplex · long edge", shortEdge = "Duplex · short edge"
    public var cupsValue: String {
        switch self { case .off: return "one-sided"; case .longEdge: return "two-sided-long-edge"; case .shortEdge: return "two-sided-short-edge" }
    }
    public var driverValue: String {
        switch self { case .off: return "None"; case .longEdge: return "DuplexNoTumble"; case .shortEdge: return "DuplexTumble" }
    }
}
public enum PrintColor: String, Codable, CaseIterable, Sendable { case color = "Color", grayscale = "Black & white" }

public struct PrintTemplate: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var printerID: String
    public var paper: PrintPaper
    public var orientation: PrintOrientation
    public var duplex: PrintDuplex
    public var pagesPerSide: Int
    public var printAsImage: Bool
    public var dpi: Int
    public var color: PrintColor
    public var startEachFileOnNewSheet: Bool
    public init(id: UUID = UUID(), name: String = "New template", printerID: String = "", paper: PrintPaper = .a4,
                orientation: PrintOrientation = .portrait, duplex: PrintDuplex = .off, pagesPerSide: Int = 1,
                printAsImage: Bool = false, dpi: Int = 300, color: PrintColor = .color, startEachFileOnNewSheet: Bool = true) {
        self.id = id; self.name = name; self.printerID = printerID; self.paper = paper
        self.orientation = orientation; self.duplex = duplex; self.pagesPerSide = pagesPerSide
        self.printAsImage = printAsImage; self.dpi = dpi; self.color = color
        self.startEachFileOnNewSheet = startEachFileOnNewSheet
    }
    public var pageSize: CGSize {
        orientation == .portrait ? paper.size : CGSize(width: paper.size.height, height: paper.size.width)
    }
    public func validate() throws {
        guard [1, 2, 4].contains(pagesPerSide), [150, 300, 600].contains(dpi) else { throw PrintError.message("Invalid print template. Choose 1, 2, or 4 pages per side and a supported image resolution.") }
    }
}

public struct PrintInput: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let pages: Int
    public var copies: Int
    public init(url: URL, pages: Int, id: UUID = UUID(), copies: Int = 1) {
        self.id = id; self.url = url; self.pages = pages; self.copies = copies
    }
}
public enum PrintError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
public struct PrintPageReference: Equatable, Sendable {
    public let document: Int
    public let page: Int
}
public struct PrintPlan: Sendable {
    /// Each array is a physical sheet side; empty arrays represent intentional blank backs.
    public let sides: [[PrintPageReference]]
    public let duplex: Bool
    public var sheetCount: Int { duplex ? (sides.count + 1) / 2 : sides.count }
    public init(pageCounts: [Int], template: PrintTemplate, copies: [Int]? = nil) throws {
        try template.validate()
        guard !pageCounts.isEmpty, pageCounts.allSatisfy({ $0 > 0 }) else { throw PrintError.message("Add at least one readable PDF.") }
        let counts = copies ?? Array(repeating: 1, count: pageCounts.count)
        guard counts.count == pageCounts.count, counts.allSatisfy({ (1...999).contains($0) }) else {
            throw PrintError.message("Choose between 1 and 999 copies for each PDF.")
        }
        var result: [[PrintPageReference]] = []
        var pending: [PrintPageReference] = []
        for (document, count) in pageCounts.enumerated() {
            for copy in 0..<counts[document] {
                for page in 0..<count {
                    pending.append(PrintPageReference(document: document, page: page))
                    if pending.count == template.pagesPerSide { result.append(pending); pending = [] }
                }
                // Copies of the same document always remain separate physical sets.
                if template.startEachFileOnNewSheet || copy < counts[document] - 1 {
                    if !pending.isEmpty { result.append(pending); pending = [] }
                    if template.duplex != .off && result.count % 2 != 0 { result.append([]) }
                }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        // Include a blank back for an odd duplex job so collated copies cannot share a sheet.
        if template.duplex != .off && result.count % 2 != 0 { result.append([]) }
        sides = result
        duplex = template.duplex != .off
    }
}

public enum PrintComposer {
    public static func inspect(_ urls: [URL]) throws -> [PrintInput] {
        guard !urls.isEmpty else { throw PrintError.message("Choose one or more PDF files.") }
        return try urls.map { url in
            try Task.checkCancellation()
            guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { throw PrintError.message("Print PDF accepts PDF files only. Convert DOCX files with Create PDF first.") }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values?.isRegularFile == true, values?.isReadable == true,
                  let document = PDFDocument(url: url) else { throw PrintError.message("Cannot read \(url.lastPathComponent). Download the file locally and check that it is a valid PDF.") }
            guard !document.isLocked else { throw PrintError.message("\(url.lastPathComponent) is locked. Save an unlocked PDF before printing.") }
            guard document.allowsPrinting else { throw PrintError.message("\(url.lastPathComponent) does not allow printing.") }
            guard document.pageCount > 0 else { throw PrintError.message("\(url.lastPathComponent) has no pages.") }
            return PrintInput(url: url, pages: document.pageCount)
        }
    }

    public static func cellRects(template: PrintTemplate) -> [CGRect] {
        let size = template.pageSize
        let columns = template.pagesPerSide == 1 ? 1 : 2
        let rows = template.pagesPerSide == 4 ? 2 : 1
        let margin: CGFloat = 18
        let gap: CGFloat = 12
        let width = (size.width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (size.height - margin * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<template.pagesPerSide).map { slot in
            let row = slot / columns, column = slot % columns
            return CGRect(x: margin + CGFloat(column) * (width + gap), y: size.height - margin - CGFloat(row + 1) * height - CGFloat(row) * gap, width: width, height: height)
        }
    }

    /// Compose the whole job, including each document's collated copies. Submit this PDF once.
    public static func prepare(urls: [URL], template: PrintTemplate, output: URL, copies: [Int]? = nil,
                               progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> PrintPlan {
        let inputs = try inspect(urls)
        let plan = try PrintPlan(pageCounts: inputs.map(\.pages), template: template, copies: copies)
        let documents = try inputs.map { input -> PDFDocument in
            guard let document = PDFDocument(url: input.url) else { throw PrintError.message("A source PDF changed. Add the files again.") }
            return document
        }
        var media = CGRect(origin: .zero, size: template.pageSize)
        guard let context = CGContext(output as CFURL, mediaBox: &media, [kCGPDFContextTitle: "PDFMe print job"] as CFDictionary) else {
            throw PrintError.message("Could not prepare the print file.")
        }
        var complete = false
        defer { context.closePDF(); if !complete { try? FileManager.default.removeItem(at: output) } }
        let cells = cellRects(template: template)
        for (sideIndex, side) in plan.sides.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
                if template.printAsImage && !side.isEmpty {
                    let scale = CGFloat(template.dpi) / 72
                    let width = Int(ceil(media.width * scale)), height = Int(ceil(media.height * scale))
                    guard width * height <= 80_000_000 else { throw PrintError.message("This paper size at \(template.dpi) dpi needs too much memory. Choose a lower image resolution.") }
                    let gray = template.color == .grayscale
                    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
                    let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
                    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
                        throw PrintError.message("Not enough memory to render this sheet. Choose a lower image resolution.")
                    }
                    bitmap.scaleBy(x: scale, y: scale)
                    bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(media)
                    try draw(side, documents: documents, cells: cells, in: bitmap)
                    guard let image = bitmap.makeImage() else { throw PrintError.message("Could not render the print image.") }
                    context.draw(image, in: media)
                } else {
                    try draw(side, documents: documents, cells: cells, in: context)
                }
                context.endPDFPage()
            }
            progress(sideIndex + 1, plan.sides.count)
        }
        complete = true
        return plan
    }

    private static func draw(_ side: [PrintPageReference], documents: [PDFDocument], cells: [CGRect], in context: CGContext) throws {
        for (slot, ref) in side.enumerated() {
            try Task.checkCancellation()
            guard let page = documents[ref.document].page(at: ref.page), let cgPage = page.pageRef else { throw PrintError.message("A PDF page could not be rendered.") }
            let bounds = cgPage.getBoxRect(.cropBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw PrintError.message("A PDF page has invalid dimensions.") }
            context.saveGState()
            context.clip(to: cells[slot])
            context.concatenate(cgPage.getDrawingTransform(.cropBox, rect: cells[slot], rotate: 0, preserveAspectRatio: true))
            context.interpolationQuality = .high
            context.drawPDFPage(cgPage)
            for annotation in page.annotations where annotation.shouldPrint { annotation.draw(with: .cropBox, in: context) }
            context.restoreGState()
        }
    }
}

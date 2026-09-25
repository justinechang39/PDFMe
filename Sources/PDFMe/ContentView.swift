import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFMeCore

private let ink = Color(red: 0.16, green: 0.20, blue: 0.18)
private let moss = Color(red: 0.24, green: 0.37, blue: 0.27)
private let muted = Color(red: 0.43, green: 0.46, blue: 0.41)
private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var printing: PrintModel
    @State private var printTargeted = false
    init(model: AppModel) { self.model = model; self.printing = model.printing }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.printingMode { PrintReviewView(model: printing) }
                    else if model.settings { settingsView.transition(.opacity.combined(with: .move(edge: .trailing))) }
                    else {
                        dropZone
                        printDropZone
                        if !model.engineReady { engineNotice }
                        if let message = model.message { banner(message) }
                        if !model.jobs.isEmpty { results }
                        options
                    }
                }.padding(24)
            }.scrollIndicators(.hidden)
            if model.printingMode { PrintActionBar(model: printing) } else { footer }
        }
        .frame(width: 420, height: 700)
        .background(paper)
        .foregroundStyle(ink)
        .tint(moss)
        .preferredColorScheme(.light)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.84), value: model.settings)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: targeted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.message)
        .onAppear { model.refreshEngine() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.printingMode {
                Button { model.printingMode = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Back").accessibilityLabel("Back to PDFMe")
            }
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(moss)
                .frame(width: 36, height: 36).background(moss.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            Text(model.printingMode ? "Print PDF" : "PDFMe").font(.system(size: 20, weight: .semibold, design: .rounded))
            Spacer()
            Button { withAnimation { if model.printingMode { printing.showTemplateEditor.toggle() } else { model.settings.toggle() } } } label: {
                Image(systemName: model.settings ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 30)
            }.buttonStyle(.plain).help(model.settings ? "Back to converter" : "Settings")
                .accessibilityLabel(model.settings ? "Back to converter" : "Settings")
        }.padding(.horizontal, 22).padding(.vertical, 18)
        .background(Color.white.opacity(0.4))
        .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.07)).frame(height: 1) }
    }

    private var dropZone: some View {
        Button(action: model.chooseFiles) {
            VStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.6)).frame(width: 43, height: 56).rotationEffect(.degrees(-13)).offset(x: -17, y: -1)
                    RoundedRectangle(cornerRadius: 11).fill(Color.white).frame(width: 43, height: 56).rotationEffect(.degrees(9)).offset(x: 13, y: 2)
                    Image(systemName: model.busy ? "ellipsis" : "arrow.down")
                        .font(.system(size: 23, weight: .medium)).foregroundStyle(moss).offset(x: 12, y: 3)
                }.frame(height: 45).scaleEffect(targeted || hovering ? 1.07 : 1)
                VStack(spacing: 6) {
                    Text(targeted ? "Drop to convert" : model.busy ? "Converting…" : "Create PDF")
                        .font(.system(size: 17, weight: .semibold))
                    Text(model.busy ? "Processing documents locally" : "Drop DOCX files here, or click to browse")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                HStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 9))
                    Text(".DOCX ONLY").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1)
                }.foregroundStyle(moss).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.white.opacity(0.65), in: Capsule())
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .background(targeted ? Color(red: 0.82, green: 0.88, blue: 0.77) : Color(red: 0.89, green: 0.92, blue: 0.85), in: RoundedRectangle(cornerRadius: 19))
            .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(moss.opacity(targeted ? 0.75 : 0.25), style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 5])).padding(5) }
            .contentShape(RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(.plain)
        .onHover { value in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { hovering = value } }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .accessibilityLabel("Create PDF. Drop DOCX files or click to browse.")
    }

    private var printDropZone: some View {
        Button { model.openPrint() } label: {
            HStack(spacing: 14) {
                Image(systemName: "printer").font(.system(size: 24)).foregroundStyle(moss).frame(width: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(printTargeted ? "Drop PDFs to print" : "Print PDF").font(.system(size: 15, weight: .semibold))
                    Text("PDF only · templates, copies and layout").font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(muted)
            }.padding(17).frame(maxWidth: .infinity)
                .background(printTargeted ? moss.opacity(0.17) : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(moss.opacity(printTargeted ? 0.6 : 0.16), lineWidth: 1) }
        }.buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $printTargeted) { providers in
                loadFileURLs(providers) { urls in model.openPrint(); printing.accept(urls) }
                return true
            }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("OPTIONS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5); Spacer() }
                .foregroundStyle(muted)
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(moss).frame(width: 20)
                    Text("PDF quality").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("PDF quality", selection: $model.quality) {
                        ForEach(PDFQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 127).controlSize(.small)
                }.padding(13)
                Divider().overlay(ink.opacity(0.02)).padding(.horizontal, 13)
                optionToggle("Password protection", subtitle: "Set a password for each batch", icon: "lock", binding: $model.protect)
                Divider().padding(.horizontal, 13)
                optionToggle("Ask every time", subtitle: "Choose where each PDF is saved", icon: "folder", binding: $model.askEveryTime)
            }.background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).stroke(ink.opacity(0.07), lineWidth: 1) }
                .disabled(model.busy)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).padding(.top, 1)
                Text(model.askEveryTime ? "Choose a save location for each PDF" : "Save beside the original document")
                    .font(.system(size: 10))
            }.foregroundStyle(muted)
        }
    }

    private func optionToggle(_ title: String, subtitle: String, icon: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(moss).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer()
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }.padding(13)
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: model.messageIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.message = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.foregroundStyle(model.messageIsError ? Color(red: 0.6, green: 0.27, blue: 0.13) : moss)
            .padding(12).background((model.messageIsError ? Color.orange : moss).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.busy ? "CONVERTING" : "RESULTS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(muted)
                Spacer()
                if model.busy {
                    Text("\(model.jobs.filter(\.finished).count)/\(model.jobs.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    Button("Cancel", action: model.cancel).font(.system(size: 10)).buttonStyle(.plain)
                } else {
                    Button("Clear") { model.jobs = []; model.message = nil }.font(.system(size: 10)).buttonStyle(.plain)
                }
            }
            if model.busy {
                ProgressView(value: Double(model.jobs.filter(\.finished).count), total: Double(model.jobs.count)).tint(moss)
            }
            ForEach(model.jobs) { job in
                HStack(alignment: .top, spacing: 10) {
                    if !job.finished && job.state != "Waiting" { ProgressView().controlSize(.small).frame(width: 24, height: 28) }
                    else { Image(systemName: job.output != nil ? "checkmark.circle.fill" : job.failed ? "exclamationmark.circle" : "doc.text").foregroundStyle(job.failed ? Color.orange : moss).frame(width: 24, height: 28) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.output?.lastPathComponent ?? job.source.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).help(job.source.lastPathComponent)
                        Text(job.state).font(.system(size: 10)).foregroundStyle(job.failed ? Color(red: 0.6, green: 0.27, blue: 0.13) : muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let output = job.output {
                        Button { NSWorkspace.shared.open(output) } label: { Image(systemName: "arrow.up.right").frame(width: 24, height: 26) }.help("Open PDF").accessibilityLabel("Open \(output.lastPathComponent)")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([output]) } label: { Image(systemName: "folder").frame(width: 24, height: 26) }.help("Show in Finder").accessibilityLabel("Show \(output.lastPathComponent) in Finder")
                    }
                }.buttonStyle(.plain).padding(11).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var engineNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Install LibreOffice", systemImage: "arrow.down.circle").font(.system(size: 13, weight: .semibold))
            Text("Install LibreOffice in Applications to enable DOCX conversion.").font(.system(size: 11)).foregroundStyle(muted)
            HStack {
                Link("Get LibreOffice ↗", destination: URL(string: "https://www.libreoffice.org/download/download-libreoffice/")!)
                Spacer()
                Button("Check again", action: model.refreshEngine)
            }.font(.system(size: 11))
        }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings").font(.system(size: 30, design: .serif))
            options
            VStack(alignment: .leading, spacing: 12) {
                Text("Image quality").font(.system(size: 14, weight: .semibold))
                ForEach(PDFQuality.allCases, id: \.self) { quality in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(quality.rawValue).font(.system(size: 12, weight: .medium))
                        Text(quality.detail).font(.system(size: 11)).foregroundStyle(muted)
                    }
                }
                Text("Quality adjusts images. Text stays sharp and selectable in every preset.").font(.system(size: 11)).foregroundStyle(muted)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Local processing", systemImage: "lock.shield").font(.system(size: 13, weight: .medium))
                Text("No uploads, accounts, or analytics. LibreOffice handles conversion locally. Fonts and complex Word layouts can look slightly different; review important documents after conversion.").font(.system(size: 11)).foregroundStyle(muted)
                Text("Passwords are used for one batch and never stored. Password protection is applied by macOS PDFKit.").font(.system(size: 11)).foregroundStyle(muted)
            }
            HStack {
                Circle().fill(model.engineReady ? moss : .orange).frame(width: 6, height: 6)
                Text(model.engineReady ? "LibreOffice is ready" : "LibreOffice isn’t installed").font(.system(size: 11))
                Spacer()
                Button("Check", action: model.refreshEngine).font(.system(size: 11)).buttonStyle(.plain)
            }
            Link("Source code ↗", destination: URL(string: "https://github.com/justinechang39/PDFMe")!).font(.system(size: 12))
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Circle().fill(moss).frame(width: 5, height: 5)
            Text("PROCESSED LOCALLY").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.3)
            Spacer()
            Text("v1.1.1").font(.system(size: 10)).foregroundStyle(muted)
            Menu {
                Button("About PDFMe") { model.settings = true }
                Link("Source code", destination: URL(string: "https://github.com/justinechang39/PDFMe")!)
                Divider()
                Button(model.busy || printing.busy ? "Stop work & quit" : "Quit PDFMe") {
                    model.cancel()
                    printing.cancelPreparation()
                    Task {
                        if let current = model.task { await current.value }
                        if let current = printing.operation { await current.value }
                        printing.cleanup()
                        NSApp.terminate(nil)
                    }
                }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More options")
        }.foregroundStyle(moss).padding(.horizontal, 24).padding(.vertical, 14)
        .background(Color.white.opacity(0.35))
        .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.07)).frame(height: 1) }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url { urls.append(url) }
            }
            guard urls.count == providers.count else { model.inform("One of those items couldn’t be read. Drop files directly from Finder.", error: true); return }
            model.accept(urls)
        }
    }
}

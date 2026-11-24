import AppKit
import PDFKit
import SwiftUI
import TinyRefs

@MainActor @Observable
final class PDFSession: Identifiable {
    let id = UUID()
    let reference: BibliographicReference
    let attachmentID: UUID
    let url: URL
    let document: PDFDocument
    let view = PDFView()
    var showsFind = false
    var findRequest = 0
    var query = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex = 0

    init(reference: BibliographicReference, attachmentID: UUID, url: URL, document: PDFDocument) {
        self.reference = reference
        self.attachmentID = attachmentID
        self.url = url
        self.document = document
        view.document = document
        view.displayMode = .singlePageContinuous
        view.autoScales = true
    }

    var pageNumber: Int {
        guard let page = view.currentPage else { return 1 }
        return document.index(for: page) + 1
    }

    func goToPage(_ number: Int) {
        guard (1...document.pageCount).contains(number), let page = document.page(at: number - 1) else { return }
        view.go(to: page)
    }

    func showFind() {
        showsFind = true
        findRequest += 1
    }

    func find() {
        matches = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        for selection in matches { selection.color = .systemYellow }
        view.highlightedSelections = matches
        matchIndex = 0
        if let first = matches.first { view.go(to: first) }
    }

    func advanceMatch(by offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
        view.go(to: matches[matchIndex])
    }
}

@MainActor
func findPDF(for reference: BibliographicReference, in store: any LibraryStore) async throws -> PDFSession? {
    let attachments = try await store.attachments(for: reference.id).filter(\.isPDF)
    var firstUnavailable: String?
    for attachment in attachments {
        do {
            let url = try await store.attachmentFile(for: reference.id, attachmentID: attachment.id)
            if let document = PDFDocument(url: url), document.pageCount > 0 {
                return PDFSession(reference: reference, attachmentID: attachment.id, url: url, document: document)
            }
            firstUnavailable = firstUnavailable ?? attachment.originalFilename
        } catch LibraryError.missingAttachmentFile(let name) {
            firstUnavailable = firstUnavailable ?? name
        }
    }
    if let name = firstUnavailable { throw WindowError.cannotOpen(name) }
    return nil
}

extension AttachmentRecord {
    var isPDF: Bool { URL(fileURLWithPath: originalFilename).pathExtension.lowercased() == "pdf" }
}

@MainActor
func openInPreview(_ url: URL) async throws {
    guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
        throw WindowError.cannotOpen(url.lastPathComponent)
    }
    _ = try await NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: .init())
}

struct PDFReaderPane: View {
    @Bindable var session: PDFSession
    @State private var pageField = "1"
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            if session.showsFind { findBar }
            Divider()
            EmbeddedPDFView(pdfView: session.view)
                .accessibilityLabel("PDF document")
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: session.view)) { _ in
            pageField = String(session.pageNumber)
        }
        .onChange(of: session.findRequest) { _, _ in findFocused = true }
        .task(id: session.query) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                session.find()
            } catch { return }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(session.url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Previous Page", systemImage: "chevron.up") {
                session.goToPage(session.pageNumber - 1)
            }
            TextField("Page", text: $pageField)
                .frame(width: 38)
                .multilineTextAlignment(.center)
                .onSubmit {
                    if let page = Int(pageField) { session.goToPage(page) }
                    pageField = String(session.pageNumber)
                }
            Text("of \(session.document.pageCount)").monospacedDigit().foregroundStyle(.secondary)
            Button("Next Page", systemImage: "chevron.down") {
                session.goToPage(session.pageNumber + 1)
            }
            Divider().frame(height: 16)
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { session.view.zoomOut(nil) }
            Button("Fit PDF", systemImage: "arrow.up.left.and.arrow.down.right") { session.view.autoScales = true }
            Button("Zoom In", systemImage: "plus.magnifyingglass") { session.view.zoomIn(nil) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.bar)
    }

    private var findBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in PDF", text: $session.query)
                .focused($findFocused)
                .onSubmit { session.advanceMatch(by: 1) }
            if !session.query.isEmpty {
                Text(session.matches.isEmpty ? "No matches" : "\(session.matchIndex + 1) of \(session.matches.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Previous Match", systemImage: "chevron.up") { session.advanceMatch(by: -1) }
                .disabled(session.matches.isEmpty)
            Button("Next Match", systemImage: "chevron.down") { session.advanceMatch(by: 1) }
                .disabled(session.matches.isEmpty)
            Button("Close Find", systemImage: "xmark") {
                session.query = ""
                session.find()
                session.showsFind = false
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
        .onAppear { findFocused = true }
    }
}

private struct EmbeddedPDFView: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

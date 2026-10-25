import BookLibCore
import SwiftUI

private struct LibraryRow: Identifiable, Hashable {
    var id: String
    var state: ConversionState
    var queued: Bool
    var title: String
    var author: String
    var duration: Int
    var year: Int
    var narrator: String
    var series: String
    var genre: String
    var parts: Int
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var sortOrder: [KeyPathComparator<LibraryRow>] = []

    private var rows: [LibraryRow] {
        model.libraryBooks.map { b in
            LibraryRow(
                id: b.asin, state: b.applicableState(multiPart: model.multiPart),
                queued: model.queuedBooks.contains(b.asin), title: b.title, author: b.author ?? "",
                duration: b.whole.runtimeSeconds ?? 0, year: b.releaseYear ?? 0, narrator: b.narrator ?? "",
                series: b.series.compactMap { s in s.title.map { "\($0) [\(s.sequenceString)]" } }.joined(separator: ", "),
                genre: b.genres.first?.joined(separator: " › ") ?? "", parts: b.parts.count)
        }
    }

    private var selectedBook: Book? {
        selection.first.flatMap { model.store.book($0) }
    }

    private var queueSummary: String {
        let rows = model.queueRows
        let books = model.queuedBooks.count
        let parts = rows.count
        return "\(books) \(books == 1 ? "Book" : "Books") / \(parts) \(parts == 1 ? "Part" : "Parts")"
    }

    var body: some View {
        let rows = rows.sorted(using: sortOrder)
        VStack(spacing: 12) {
            HStack {
                Text("Library for “\(model.accountAlias ?? "")”")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            toolbar

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("State", value: \.state.rawValue) { row in
                    StateIcon(state: row.queued ? .download : row.state)
                        .padding(3)
                        .background(row.queued ? Color.cyan.opacity(0.28) : .clear, in: .capsule)
                }
                .width(52)
                TableColumn("Title", value: \.title) { Text($0.title).lineLimit(1) }
                    .width(min: 140, ideal: 220)
                TableColumn("Author", value: \.author) { Text($0.author).lineLimit(1) }
                    .width(min: 80, ideal: 110)
                TableColumn("Duration", value: \.duration) { Text(Fmt.duration($0.duration)).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("Year", value: \.year) { Text(Fmt.year($0.year)).monospacedDigit() }
                    .width(min: 48, ideal: 54)
                TableColumn("Narrator", value: \.narrator) { Text($0.narrator).lineLimit(1) }
                    .width(min: 80, ideal: 100)
                TableColumn("Series", value: \.series) { Text($0.series).lineLimit(1) }
                    .width(min: 80, ideal: 120)
                TableColumn("Genre", value: \.genre) { Text($0.genre).lineLimit(1) }
                    .width(min: 80, ideal: 120)
                TableColumn("Parts", value: \.parts) { Text($0.parts > 0 ? String($0.parts) : "").monospacedDigit() }
                    .width(48)
            }
            .scrollContentBackground(.hidden)
            .clipShape(.rect(cornerRadius: 20))
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .frame(minHeight: 230)

            BookDetailView(book: selectedBook)
                .frame(height: 190)
        }
        .padding(18)
        .frame(minWidth: 1060, idealWidth: 1120, minHeight: 700, idealHeight: 760)
        .background(BrandBackdrop())
        .onChange(of: model.queuedBooks) { _, _ in }
    }

    private var toolbar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Text("Download:").foregroundStyle(.secondary)
                Button("Add selected") {
                    model.addToQueue(Array(selection))
                }
                .disabled(selection.isEmpty || model.isRunning)
                Button("Rem. selected") {
                    model.removeFromQueue(books: Array(selection))
                }
                .disabled(selection.isEmpty || model.isRunning)
                Button("Remove all") { model.removeAllFromQueue() }
                    .disabled(model.queuedBooks.isEmpty || model.isRunning)

                Text(queueSummary)
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)

                Spacer()

                Button("Resync") { Task { await resync() } }
                    .disabled(model.isRunning)
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func resync() async {
        let answer = await model.confirm(
            title: "Full library resynchronization",
            message: "Yes: full library resynchronization, add and remove books.\nNo: only add new books since the last purchase.\nCancel: do nothing.",
            buttons: ["Yes", "No", "Cancel"])
        guard answer != 2 else { return }
        await model.syncLibrary(resync: answer == 0)
    }
}

// MARK: - Details

struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    let book: Book?

    var body: some View {
        HStack(spacing: 12) {
            GlassPanel(padding: 0) {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        ForEach(properties, id: \.0) { name, value in
                            GridRow {
                                Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(value).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 330)

            GlassPanel(padding: 0) {
                ScrollView {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            CoverImage(url: book.flatMap { model.store.coverURL(for: $0) })
                .frame(width: 190)
        }
    }

    private var summary: String {
        guard let s = book?.publisherSummary ?? book?.merchandisingSummary else { return "" }
        return ConversionJobText.stripHTML(s)
    }

    private var properties: [(String, String)] {
        guard let b = book else { return [] }
        let multi = model.multiPart
        var p: [(String, String)] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { p.append((name, value)) }
        }
        add("State", b.applicableState(multiPart: multi).label)
        add("Title", b.title)
        add("Subtitle", b.subtitle)
        add("Author", b.allAuthors)
        add("Duration", Fmt.duration(b.whole.runtimeSeconds ?? 0))
        add("Unabridged", b.unabridged.map { $0 ? "Yes" : "No" })
        add("Language", b.language)
        add("Release date", b.releaseDate.map(Fmt.date.string))
        add("Purchase date", b.purchaseDate.map(Fmt.date.string))
        add("Narrator", b.allNarrators)
        add("Publisher", b.publisherName)
        add("Series", b.series.compactMap { s in s.title.map { "\($0) [\(s.sequenceString)]" } }.joined(separator: ", "))
        add("Genre", b.genres.first?.joined(separator: " › "))
        add("Average rating", b.averageRating.map { String(format: "%.1f", $0) })
        add("Delivery type", b.deliveryType?.label)
        add("Adult product", b.adultProduct.map { $0 ? "Yes" : "No" })
        add("Parts", b.hasParts ? String(b.parts.count) : nil)
        add("File size", Fmt.size(b.units(multiPart: multi).compactMap(\.fileSizeBytes).reduce(0, +)))
        add("Sample rate", b.whole.sampleRate.map { Fmt.hz($0) })
        add("Bit rate", b.whole.bitRate.map { Fmt.kbps($0) })
        return p
    }
}

/// Text helpers shared with the conversion pipeline.
enum ConversionJobText {
    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

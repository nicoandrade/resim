import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    private static let imageIcon = NSWorkspace.shared.icon(for: UTType.image)
    let model: AppModel
    @State private var selection = Set<UUID>()
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            if model.hasActiveJobs {
                ProgressView(value: model.progress, total: 1)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Batch progress")
                    .accessibilityValue("\(Int(model.progress * 100)) %")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            Group {
                if model.jobs.isEmpty { emptyState } else { jobTable }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: receiveDrop)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(reduceTransparency ? 0 : 0.06))
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 340)
        .background(WindowCloseObserver(model: model).frame(width: 0, height: 0))
        .onExitCommand { if model.hasActiveJobs { model.cancelAll() } }
        .onChange(of: model.totalCount) { previous, current in
            guard current < previous, !selection.isEmpty else { return }
            selection.formIntersection(Set(model.jobs.map(\.id)))
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if #available(macOS 26.0, *) {
                batchSummaryItem.sharedBackgroundVisibility(.hidden)
            } else {
                batchSummaryItem
            }
            if model.hasActiveJobs {
                ToolbarItem(placement: .automatic) {
                    Button("Cancel") { model.cancelAll() }
                        .accessibilityIdentifier("cancel-batch")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { ImagePicker.present(model: model) } label: {
                    Label("Add Images…", systemImage: "plus").labelStyle(.iconOnly)
                }
                .help("Add images (⌘O)")
                .accessibilityIdentifier("add-images")
            }
        }
    }

    private var batchSummaryItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(model.jobs.isEmpty ? "" : summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Keep the toolbar's flexible space when the list is empty.
                .frame(minWidth: 1)
                .help(model.jobs.isEmpty ? "" : summary)
                .accessibilityIdentifier("batch-summary")
                .accessibilityHidden(model.jobs.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Drop images here").font(.title2)
            Text("PNG, JPEG, WebP, HEIC, AVIF, GIF, and SVG").foregroundStyle(.secondary)
            Button("Add Images…") { ImagePicker.present(model: model) }
                .controlSize(.large)
                .padding(.top, 2)
                .accessibilityIdentifier("empty-add-images")
        }
        .padding(24)
    }

    private var summary: String {
        if model.hasActiveJobs {
            return String.localizedStringWithFormat(String(localized: "%lld of %lld completed · %@ saved"), model.finishedCount, model.totalCount, DisplayFormat.bytes(model.savedBytes))
        }
        var parts = [String.localizedStringWithFormat(String(localized: "%lld completed"), model.completedCount)]
        if model.excludedCount > 0 { parts.append(String.localizedStringWithFormat(String(localized: "%lld unsupported"), model.excludedCount)) }
        if model.cancelledCount > 0 { parts.append(String.localizedStringWithFormat(String(localized: "%lld cancelled"), model.cancelledCount)) }
        if model.failedCount > 0 { parts.append(String.localizedStringWithFormat(String(localized: "%lld failed"), model.failedCount)) }
        parts.append(String.localizedStringWithFormat(String(localized: "%@ saved"), DisplayFormat.bytes(model.savedBytes)))
        return parts.joined(separator: " · ")
    }

    private var jobTable: some View {
        let stripedRows = Set(model.jobs.enumerated().compactMap { index, job in
            index.isMultiple(of: 2) ? nil : job.id
        })
        return Table(model.jobs, selection: $selection) {
            TableColumn("File") { job in
                HStack(spacing: 7) {
                    JobStatusIcon(state: job.state)
                    Image(nsImage: Self.imageIcon)
                        .resizable().frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: job.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(job.filename)
                        if job.state == .failed {
                            Text(job.message ?? job.state.title)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .background(ContentRowBackground(striped: stripedRows.contains(job.id)))
                .help(job.message ?? job.state.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(job.accessibilitySummary)
            }.width(min: 140, ideal: 220, max: 260)
            TableColumn("Original") { job in
                sizeCell(job.originalBytes)
            }.width(min: 75, ideal: 85, max: 110)
            TableColumn("Result") { job in
                sizeCell(job.resultBytes)
            }.width(min: 75, ideal: 85, max: 110)
            TableColumn("Savings") { job in
                Text(job.savingsLabel).monospacedDigit()
                    .foregroundStyle(job.savedBytes > 0 ? Color.green : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 60, ideal: 70, max: 85)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let job = selectedJob(ids) {
                Button("Show Original in Finder") { reveal(job.sourceURL) }
                Button("Show Result in Finder") { if let url = job.resultURL { reveal(url) } }
                    .disabled(job.resultURL == nil)
                if job.state.canRetry {
                    Divider()
                    Button("Retry") { model.retry(job.id) }
                }
            }
        } primaryAction: { ids in
            if let url = selectedJob(ids)?.resultURL { reveal(url) }
        }
        .accessibilityIdentifier("jobs-table")
    }

    private func sizeCell(_ bytes: Int64?) -> some View {
        Text(bytes.map(DisplayFormat.bytes) ?? "—")
            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }
    private var footer: some View {
        HStack {
            Text(String.localizedStringWithFormat(String(localized: "%lld images"), model.jobs.count)).foregroundStyle(.secondary)
            Spacer()
            Button("Clear List") { model.clearFinished() }
            .disabled(model.finishedCount == 0)
            .accessibilityIdentifier("clear-list")
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .help("Settings")
            .accessibilityIdentifier("open-settings")
        }
        .font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
    }
    private func selectedJob(_ ids: Set<UUID>) -> ImageJob? {
        ids.count == 1 ? model.jobs.first { ids.contains($0.id) } : nil
    }
    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        model.receiveDrop(providers)
    }

}

/// Color actual AppKit rows without extending the alternating pattern into empty space.
private struct ContentRowBackground: NSViewRepresentable {
    let striped: Bool

    func makeNSView(context: Context) -> RowHook { RowHook() }

    func updateNSView(_ view: RowHook, context: Context) {
        view.striped = striped
        view.updateRowBackground()
    }

    final class RowHook: NSView {
        var striped = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRowBackground()
        }

        override func layout() {
            super.layout()
            updateRowBackground()
        }

        func updateRowBackground() {
            var ancestor = superview
            while let view = ancestor {
                if let row = view as? NSTableRowView {
                    let colors = NSColor.alternatingContentBackgroundColors
                    row.backgroundColor = striped ? colors[1] : colors[0]
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

@MainActor
enum ImagePicker {
    static func present(model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Images")
        panel.prompt = String(localized: "Add")
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .heif, .gif, .svg] + [UTType(filenameExtension: "avif")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            model.addURLs(panel.urls)
        }
    }
}

nonisolated enum DisplayFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension JobState {
    var tint: Color {
        switch self {
        case .optimized: .green
        case .failed: .red
        default: .secondary
        }
    }

    var title: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Processing")
        case .optimized: String(localized: "Optimized")
        case .unchanged: String(localized: "No Reduction")
        case .unsupported: String(localized: "Unsupported")
        case .cancelled: String(localized: "Cancelled")
        case .failed: String(localized: "Error")
        }
    }
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.right.circle"
        case .optimized: "checkmark.circle.fill"
        case .unchanged: "minus.circle"
        case .unsupported: "nosign"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

extension ImageJob {
    var savingsLabel: String {
        guard let originalBytes, let resultBytes, originalBytes > 0 else { return "—" }
        let ratio = max(0, Double(originalBytes - resultBytes) / Double(originalBytes))
        return ratio.formatted(.percent.precision(.fractionLength(0...1)))
    }
    var accessibilitySummary: String {
        String.localizedStringWithFormat(String(localized: "%@, %@. Original: %@. Result: %@. Savings: %@. %@"), filename, state.title, originalBytes.map(DisplayFormat.bytes) ?? "—", resultBytes.map(DisplayFormat.bytes) ?? "—", savingsLabel, message ?? "")
    }
}

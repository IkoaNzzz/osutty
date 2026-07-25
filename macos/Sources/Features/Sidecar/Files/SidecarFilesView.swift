import AppKit
import SwiftUI

struct SidecarFilesView: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    @StateObject private var model = SidecarFilesModel()
    @StateObject private var quickLook = SidecarQuickLookController()
    @State private var followsTerminalDirectory = true
    @State private var hoveredEntry: URL?
    @FocusState private var focusedControl: FocusTarget?

    private var terminalDirectory: URL? {
        guard let pwd = surfaceView.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd, isDirectory: true)
    }

    private var quickLookKeyEnabled: Bool {
        guard case .file(let url) = focusedControl else { return false }
        guard model.selection == url else { return false }
        return entry(for: url)?.isDirectory == false
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, SidecarMetrics.compactContentPadding)
                .padding(.bottom, 5)

            Group {
                if model.searchQuery.isEmpty {
                    tree
                } else {
                    searchResults
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 7)
        .background {
            SidecarQuickLookKeyMonitor(
                window: surfaceView.window,
                isEnabled: quickLookKeyEnabled
            ) {
                quickLookSelection()
            }
            .frame(width: 0, height: 0)
        }
        .task(id: terminalDirectory) {
            guard followsTerminalDirectory, let terminalDirectory else { return }
            model.setRoot(terminalDirectory)
        }
        .onChange(of: model.showsHiddenFiles) { _ in
            model.reload()
        }
        .onDisappear {
            model.cancelAll()
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            searchField

            SidecarToolbarButton(
                systemImage: "arrow.up",
                help: "Go to Parent Folder"
            ) {
                guard let root = model.root else { return }
                followsTerminalDirectory = false
                model.setRoot(root.deletingLastPathComponent())
            }

            SidecarToolbarButton(
                systemImage: "arrow.right",
                help: "Go to Folder…"
            ) {
                chooseFolder()
            }

            SidecarToolbarButton(
                systemImage: model.showsHiddenFiles ? "eye.fill" : "eye",
                help: "Toggle Hidden Files",
                isActive: model.showsHiddenFiles
            ) {
                model.showsHiddenFiles.toggle()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($focusedControl, equals: .search)
                .onSubmit(model.search)
                .accessibilityLabel("Search files")

            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    model.search()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: SidecarMetrics.controlHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    focusedControl == .search
                        ? Color.accentColor.opacity(0.45)
                        : Color.primary.opacity(0.035),
                    lineWidth: 1
                )
        }
        .animation(SidecarMetrics.contentAnimation, value: model.searchQuery.isEmpty)
    }

    @ViewBuilder
    private var tree: some View {
        if let errorMessage = model.errorMessage {
            SidecarEmptyView(
                title: "Unable to Read Folder",
                systemImage: "exclamationmark.triangle",
                description: errorMessage
            )
        } else if model.isLoading, model.rows.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty {
            SidecarEmptyView(
                title: "Empty Folder",
                systemImage: "folder",
                description: model.root?.abbreviatingWithTilde ?? "No working directory"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        fileRow(row)
                            .transition(
                                .opacity.combined(with: .move(edge: .top))
                            )
                    }
                }
            }
            .animation(SidecarMetrics.disclosureAnimation, value: model.rows)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.searchResults.isEmpty {
            SidecarEmptyView(
                title: "No Results",
                systemImage: "magnifyingglass",
                description: "Press Return to search this folder."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.searchResults) { entry in
                        searchResultRow(entry)
                    }
                }
            }
        }
    }

    private func fileRow(_ row: SidecarFileRow) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: CGFloat(row.depth) * SidecarMetrics.rowIndent)

            if row.entry.isDirectory, !row.entry.isSymbolicLink {
                Button {
                    withAnimation(SidecarMetrics.disclosureAnimation) {
                        model.toggle(row.entry)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.isExpanded(row.entry) ? 90 : 0))
                        .frame(width: SidecarMetrics.rowIndent)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidecarFocusEffectDisabled()
                .help(model.isExpanded(row.entry) ? "Collapse Folder" : "Expand Folder")
                .accessibilityLabel(
                    model.isExpanded(row.entry) ? "Collapse \(row.entry.name)" : "Expand \(row.entry.name)"
                )
            } else {
                Color.clear
                    .frame(width: SidecarMetrics.rowIndent)
            }

            Button {
                model.selection = row.entry.url
                focusFileRow(row.entry.url)
            } label: {
                HStack(spacing: 6) {
                Image(systemName: row.entry.systemImage)
                    .font(.system(size: 11))
                        .frame(width: 14)
                    .foregroundStyle(
                        row.entry.isDirectory
                            ? Color.accentColor
                            : Color.primary.opacity(0.6)
                    )

                Text(row.entry.name)
                    .font(.system(size: 11))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
                .padding(.trailing, SidecarMetrics.compactContentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedControl, equals: .file(row.entry.url))
            .sidecarFocusEffectDisabled()
            .accessibilityLabel(row.entry.name)
            .accessibilityValue(row.entry.isDirectory ? "Directory" : "File")
        }
        .frame(height: SidecarMetrics.rowHeight)
        .background {
            Rectangle()
                .fill(fileRowBackground(for: row.entry.url))
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredEntry = isHovering ? row.entry.url : nil
        }
        .animation(SidecarMetrics.contentAnimation, value: model.selection)
        .animation(SidecarMetrics.contentAnimation, value: hoveredEntry)
        .contextMenu {
            fileContextMenu(row.entry)
        }
    }

    private func searchResultRow(_ entry: SidecarFileEntry) -> some View {
        Button {
            if entry.isDirectory {
                followsTerminalDirectory = false
                model.searchQuery = ""
                model.setRoot(entry.url)
            } else {
                model.selection = entry.url
            }
            focusFileRow(entry.url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.systemImage)
                    .frame(width: 14)
                    .foregroundStyle(
                        entry.isDirectory
                            ? Color.accentColor
                            : Color.primary.opacity(0.6)
                    )

                VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text(entry.relativePath(from: model.root))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidecarMetrics.compactContentPadding)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedControl, equals: .file(entry.url))
        .sidecarFocusEffectDisabled()
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(fileRowBackground(for: entry.url))
        }
        .onHover { isHovering in
            hoveredEntry = isHovering ? entry.url : nil
        }
        .contextMenu {
            fileContextMenu(entry)
        }
    }

    @ViewBuilder
    private func fileContextMenu(_ entry: SidecarFileEntry) -> some View {
        if !entry.isDirectory {
            Button("Quick Look") {
                quickLook.preview(entry.url)
            }
        }
        Button("Open") {
            NSWorkspace.shared.open(entry.url)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
    }

    private func quickLookSelection() {
        guard let selection = model.selection,
              entry(for: selection)?.isDirectory == false else {
            return
        }
        quickLook.toggle(selection)
    }

    private func entry(for url: URL) -> SidecarFileEntry? {
        model.rows.first(where: { $0.entry.url == url })?.entry
            ?? model.searchResults.first(where: { $0.url == url })
    }

    private func fileRowBackground(for url: URL) -> Color {
        if model.selection == url {
            return Color.primary.opacity(0.075)
        }
        if hoveredEntry == url {
            return Color.primary.opacity(0.035)
        }
        return .clear
    }

    private func focusFileRow(_ url: URL) {
        Task { @MainActor in
            await Task.yield()
            focusedControl = .file(url)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Sidecar Folder"
        panel.directoryURL = model.root
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        followsTerminalDirectory = false
        model.setRoot(url)
    }
}

private enum FocusTarget: Hashable {
    case search
    case file(URL)
}

private extension SidecarFileEntry {
    var systemImage: String {
        if isSymbolicLink { return "arrow.turn.up.right" }
        if isDirectory { return "folder" }
        return "doc"
    }

    func relativePath(from root: URL?) -> String {
        guard let root else { return url.path }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

private extension URL {
    var abbreviatingWithTilde: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

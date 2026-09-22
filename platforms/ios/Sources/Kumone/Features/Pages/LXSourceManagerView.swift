#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// A dedicated LX User API manager. Playback settings intentionally do not
/// live here: this page only selects, imports, reloads, and removes sources.
struct LXSourceManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lxStore = LXSourceStore.shared
    @StateObject private var lxAPI = LXUserAPIService.shared
    @State private var isImportingFile = false
    @State private var isShowingOnlineImport = false
    @State private var onlineSourceURL = ""
    @State private var isLoadingOnline = false
    @State private var sourceToDelete: LXSourceStore.Source?
    @State private var lxError: String?
    @State private var testingSourceID: String?
    @State private var sourceCheckResults: [String: LXUserAPIService.SourceCheckResult] = [:]
    @State private var expandedSourceIDs: Set<String> = []

    var body: some View {
        content
        .navigationTitle("LX 音源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isImportingFile,
            // LX sources are commonly exported as .js, .json, .txt, or a
            // filename without an extension. Validate contents after the
            // user chooses a generic item instead of hiding valid exports.
            allowedContentTypes: [.data, .item]
        ) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result { lxError = error.localizedDescription }
                return
            }
            Task { @MainActor in
                do {
                    try await importSourceFile(at: url)
                } catch {
                    lxError = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $isShowingOnlineImport) {
            onlineImportSheet
        }
        .alert("LX 音源", isPresented: Binding(
            get: { lxError != nil },
            set: { if !$0 { lxError = nil } }
        )) {
            Button("关闭", role: .cancel) { lxError = nil }
        } message: {
            Text(lxError ?? "导入失败")
        }
        .alert("确认删除音源？", isPresented: Binding(
            get: { sourceToDelete != nil },
            set: { if !$0 { sourceToDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let sourceToDelete {
                    lxStore.remove(sourceToDelete)
                }
                sourceToDelete = nil
            }
            Button("取消", role: .cancel) { sourceToDelete = nil }
        } message: {
            Text(sourceToDelete?.name ?? "")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                managerHeader
                sourceListSection
                importSection
                statusSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var managerHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("LX User API")
                    .font(.title2.weight(.bold))
                Text(lxStore.selectedSource.map { "当前使用：\($0.name)" } ?? "导入音源后即可开始搜索和播放")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var sourceListSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                cardTitle("已添加的音源", systemImage: "checkmark.shield")
                HStack(spacing: 8) {
                    Label("已启用 \(lxStore.playbackSources.count) 个", systemImage: "bolt.fill")
                    Text("·")
                    Text("点击卡片切换首选源")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if lxStore.sources.isEmpty {
                    emptySourceView
                } else {
                    VStack(spacing: 10) {
                        ForEach(lxStore.sources) { source in
                            modernSourceRow(source)
                        }
                    }
                }

                Text("可同时启用多个音源。播放时会优先使用当前源，失败后按启用顺序自动备用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptySourceView: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
            Text("还没有 LX 音源")
                .font(.headline)
            Text("请导入 LX User API 文件，或添加在线脚本链接。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var importSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("添加音源", systemImage: "plus.circle")
                HStack(spacing: 10) {
                    importAction(
                        title: "从文件导入",
                        subtitle: ".js / .json / .txt / 无扩展名",
                        systemImage: "doc.badge.plus"
                    ) {
                        isImportingFile = true
                    }
                    importAction(
                        title: "从在线链接导入",
                        subtitle: "下载后保存到本机",
                        systemImage: "link.badge.plus"
                    ) {
                        onlineSourceURL = ""
                        isShowingOnlineImport = true
                    }
                }
                Text("导入后会自动选中并加载该音源；播放时不会再次请求在线链接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("当前音源状态", systemImage: "waveform.path.ecg")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(lxStore.selectedSource == nil ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(lxAPI.statusMessage)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                }

                if !activeCapabilitiesText.isEmpty {
                    Text(activeCapabilitiesText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                }

                if let source = lxStore.selectedSource,
                   let result = sourceCheckResults[source.id] {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: result.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isAvailable ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.message)
                                .font(.subheadline.weight(.medium))
                            if let detail = result.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("重新加载") {
                        lxAPI.loadSelectedSource()
                    }
                    .buttonStyle(.bordered)
                    .disabled(lxStore.selectedSource == nil)

                    Button {
                        if let source = lxStore.selectedSource {
                            checkSource(source)
                        }
                    } label: {
                        if testingSourceID == lxStore.selectedID {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("测试音源", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lxStore.selectedSource == nil || testingSourceID != nil)
                }

                Text("测试会请求一首公开歌曲的 musicUrl，只检查播放地址是否有效，不会保存或下载歌曲。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func glassCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private func cardTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func importAction(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var activeCapabilitiesText: String {
        lxAPI.capabilities
            .filter { !$0.value.isEmpty }
            .map { "\(LXCatalogPlatform.displayName(for: $0.key))：\($0.value.joined(separator: ", "))" }
            .sorted()
            .joined(separator: "\n")
    }

    @ViewBuilder
    private func modernSourceRow(_ source: LXSourceStore.Source) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    lxStore.select(source.id)
                } label: {
                    Image(systemName: lxStore.selectedID == source.id
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 28))
                        .foregroundStyle(lxStore.selectedID == source.id ? Theme.accent : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择音源 (source.name)")

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if lxStore.selectedID == source.id {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    let detail = [source.author, source.version]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    checkSource(source)
                } label: {
                    if testingSourceID == source.id {
                        ProgressView()
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "checkmark.shield")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.plain)
                .disabled(testingSourceID != nil)
                .accessibilityLabel("测试 (source.name)")

                Button(role: .destructive) {
                    sourceToDelete = source
                } label: {
                    Image(systemName: "trash")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除 (source.name)")
            }

            if !source.description.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(expandedSourceIDs.contains(source.id) ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        if expandedSourceIDs.contains(source.id) {
                            expandedSourceIDs.remove(source.id)
                        } else {
                            expandedSourceIDs.insert(source.id)
                        }
                    } label: {
                        Label(
                            expandedSourceIDs.contains(source.id) ? "收起描述" : "展开完整描述",
                            systemImage: expandedSourceIDs.contains(source.id)
                                ? "chevron.up" : "chevron.down"
                        )
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 32, alignment: .leading)
                }
                .padding(.leading, 54)
            }

            if let result = sourceCheckResults[source.id] {
                HStack(spacing: 4) {
                    Image(systemName: result.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(result.message)
                }
                .font(.caption)
                .foregroundStyle(result.isAvailable ? .green : .red)
                .padding(.leading, 54)
            }

            HStack(spacing: 14) {
                Toggle(
                    "启用备用播放",
                    isOn: Binding(
                        get: { lxStore.isEnabled(source.id) },
                        set: { lxStore.setEnabled(source.id, enabled: $0) }
                    )
                )
                .font(.caption)
                .tint(Theme.accent)
                .accessibilityLabel("启用音源 (source.name)")

                Spacer(minLength: 0)

                if let sourceURL = source.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Label("在线链接", systemImage: "link")
                            .font(.caption)
                    }
                } else if !source.homepage.isEmpty, let url = URL(string: source.homepage) {
                    Link(destination: url) {
                        Label("主页", systemImage: "link")
                            .font(.caption)
                    }
                }
            }
            .padding(.leading, 54)
        }
        .padding(10)
        .background(
            lxStore.selectedID == source.id
                ? Theme.accent.opacity(0.10)
                : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    lxStore.selectedID == source.id
                        ? Theme.accent.opacity(0.35)
                        : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: LXSourceStore.Source) -> some View {
        HStack(spacing: 8) {
            Button {
                lxStore.select(source.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: lxStore.selectedID == source.id
                          ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(lxStore.selectedID == source.id ? Theme.accent : .secondary)
                        .frame(width: 32, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(source.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            if lxStore.selectedID == source.id {
                                Text("当前")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        let detail = [source.author, source.version]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !source.description.isEmpty {
                            Text(source.description)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        if let result = sourceCheckResults[source.id] {
                            HStack(spacing: 4) {
                                Image(systemName: result.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                Text(result.message)
                            }
                            .font(.caption)
                            .foregroundStyle(result.isAvailable ? .green : .red)
                        }
                        if let sourceURL = source.sourceURL, let url = URL(string: sourceURL) {
                            Link(destination: url) {
                                Label("查看在线链接", systemImage: "link")
                                    .font(.caption)
                            }
                        } else if !source.homepage.isEmpty, let url = URL(string: source.homepage) {
                            Link(destination: url) {
                                Label("查看主页", systemImage: "link")
                                    .font(.caption)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 56)

            Toggle(
                "\u{542f}\u{7528} \(source.name)",
                isOn: Binding(
                    get: { lxStore.isEnabled(source.id) },
                    set: { lxStore.setEnabled(source.id, enabled: $0) }
                )
            )
            .labelsHidden()
            .frame(width: 52)
            .accessibilityLabel("\u{542f}\u{7528}\u{97f3}\u{6e90} \(source.name)")

            Button {
                checkSource(source)
            } label: {
                if testingSourceID == source.id {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "checkmark.shield")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.borderless)
            .disabled(testingSourceID != nil)
            .accessibilityLabel("测试 \\(source.name)")

            Button(role: .destructive) {
                sourceToDelete = source
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("删除 \(source.name)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                sourceToDelete = source
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func importSourceFile(at url: URL) async throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        // Read the security-scoped URL directly first. Coordinating the URL
        // before reading it breaks some Files.app providers (especially local
        // Downloads and iCloud Drive) even though the file is available.
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let directError {
            // A few document providers only expose a stable URL while it is
            // being coordinated. Keep this as a fallback, not the main path.
            var coordinationError: NSError?
            var coordinatedData: Data?
            NSFileCoordinator().coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                coordinatedData = try? Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
            }

            if let coordinatedData {
                data = coordinatedData
            } else {
                // Some providers return a temporary URL that cannot be mapped
                // directly. Copying it into our process first gives the
                // parser a normal local file and also prevents a revoked
                // provider URL from being retained by the app.
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("moumusic-lx-import-\(UUID().uuidString)")
                do {
                    try FileManager.default.copyItem(at: url, to: temporaryURL)
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }
                    data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                } catch {
                    throw coordinationError ?? directError
                }
            }
        }

        guard !data.isEmpty else {
            throw LXSourceStore.ImportError.readFailed
        }
        guard data.count <= 16_000_000 else {
            throw LXSourceStore.ImportError.tooLarge
        }

        let withoutExtension = url.deletingPathExtension().lastPathComponent
        let suggestedName = withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension

        try await lxStore.importSourceData(
            data,
            suggestedName: suggestedName.isEmpty ? "LX 音源" : suggestedName
        )
    }

    private var onlineImportSheet: some View {
        NavigationStack {
            Form {
                Section("在线脚本链接") {
                    TextField("https://example.com/source.js", text: $onlineSourceURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("导入时下载并保存本地副本，播放时使用本地副本，不会每次播放都重复请求该链接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        importOnlineSource()
                    } label: {
                        if isLoadingOnline {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("下载并添加")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isLoadingOnline || onlineSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("添加在线音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isShowingOnlineImport = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func importOnlineSource() {
        isLoadingOnline = true
        let url = onlineSourceURL
        Task {
            do {
                try await lxStore.importOnlineScript(url)
                isShowingOnlineImport = false
            } catch {
                lxError = error.localizedDescription
            }
            isLoadingOnline = false
        }
    }

    private func checkSource(_ source: LXSourceStore.Source) {
        guard testingSourceID == nil else { return }
        let previousID = lxStore.selectedID
        testingSourceID = source.id
        if previousID != source.id {
            lxStore.select(source.id)
        }
        Task { @MainActor in
            let result = await lxAPI.checkSelectedSource()
            sourceCheckResults[source.id] = result
            if previousID != source.id {
                lxStore.select(previousID)
            }
            testingSourceID = nil
        }
    }
}
#endif

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

    var body: some View {
        content
        .formStyle(.grouped)
        .navigationTitle("LX 音源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [
                .plainText,
                .json,
                .sourceCode,
                UTType(filenameExtension: "js") ?? .plainText,
            ]
        ) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try lxStore.importScript(
                    Data(contentsOf: url),
                    suggestedName: url.deletingPathExtension().lastPathComponent
                )
            } catch {
                lxError = error.localizedDescription
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

    @ViewBuilder
    private var content: some View {
        Form {
            sourceListSection
            importSection
            verifiedSourceSection
            statusSection
        }
    }

    @ViewBuilder
    private var sourceListSection: some View {
        Section {
            if lxStore.sources.isEmpty {
                emptySourceView
            } else {
                ForEach(lxStore.sources) { source in
                    sourceRow(source)
                }
            }
        } header: {
            Text("已添加的音源")
        } footer: {
            Text("点击音源行即可切换当前播放源。删除按钮固定显示在右侧，也支持左滑删除。")
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
        Section("添加音源") {
            Button {
                isImportingFile = true
            } label: {
                Label("从文件导入", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)

            Button {
                onlineSourceURL = ""
                isShowingOnlineImport = true
            } label: {
                Label("从在线链接导入", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private var verifiedSourceSection: some View {
        Section("已验证的参考音源") {
            VStack(alignment: .leading, spacing: 5) {
                Text("星海音乐源")
                    .font(.body.weight(.medium))
                Text("发布前已完成脚本加载和 musicUrl 只读验证：酷我、咪咕 128k 可返回播放地址。第三方接口会随时变动，导入后仍请用“测试当前音源”复核。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                onlineSourceURL = Self.xinghaiSourceURL
                importOnlineSource()
            } label: {
                if isLoadingOnline {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("导入星海音乐源", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(isLoadingOnline)
            .frame(minHeight: 44)

            Link(destination: URL(string: "https://github.com/cdyUuu/lx-music-xinghai-source")!) {
                Label("查看源码和在线链接", systemImage: "link")
            }
            .frame(minHeight: 44)
        } footer: {
            Text("这里只提供用户主动导入的公开脚本，不会在首次启动时自动写入或启用任何音源。")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent("状态", value: lxAPI.statusMessage)
            if !activeCapabilitiesText.isEmpty {
                Text(activeCapabilitiesText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Button("重新加载当前音源") {
                lxAPI.loadSelectedSource()
            }
            .disabled(lxStore.selectedSource == nil)
            .frame(minHeight: 44)
            Button {
                if let source = lxStore.selectedSource {
                    checkSource(source)
                }
            } label: {
                if testingSourceID == lxStore.selectedID {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("测试当前音源", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(lxStore.selectedSource == nil || testingSourceID != nil)
            .frame(minHeight: 44)
        } header: {
            Text("当前音源状态")
        } footer: {
            Text("点击“测试”会用一首公开测试歌曲请求所选音源的 musicUrl 接口，只检查是否返回有效播放地址，不会保存或下载歌曲。")
        }
    }

    private var activeCapabilitiesText: String {
        lxAPI.capabilities
            .filter { !$0.value.isEmpty }
            .map { "\($0.key)：\($0.value.joined(separator: ", "))" }
            .sorted()
            .joined(separator: "\n")
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

    private static let xinghaiSourceURL = "https://raw.githubusercontent.com/cdyUuu/lx-music-xinghai-source/main/xinghai-music-source.js"

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

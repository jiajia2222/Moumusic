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

    var body: some View {
        Form {
            Section {
                if lxStore.sources.isEmpty {
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

            Section("当前音源状态") {
                LabeledContent("状态", value: lxAPI.statusMessage)
                if !lxAPI.capabilities.isEmpty {
                    let abilities = lxAPI.capabilities
                        .filter { !$0.value.isEmpty }
                        .map { "\($0.key)：\($0.value.joined(separator: ", "))" }
                        .sorted()
                        .joined(separator: "\n")
                    Text(abilities)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("重新加载当前音源") {
                    lxAPI.loadSelectedSource()
                }
                .disabled(lxStore.selectedSource == nil)
                .frame(minHeight: 44)
            } footer: {
                Text("播放地址、歌词和封面由所选 LX User API 脚本提供。音质请到“设置 → 播放”调整。")
            }
        }
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
}
#endif

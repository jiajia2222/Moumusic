import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogView: View {
    @StateObject private var store = DiagnosticLogStore.shared
    @State private var selectedLevel = "all"
    @State private var searchText = ""
    @State private var selectedEntry: DiagnosticLogStore.Entry?
    @State private var isExporting = false

    private var filteredEntries: [DiagnosticLogStore.Entry] {
        store.entries.filter { entry in
            let levelMatches = selectedLevel == "all" || entry.level.rawValue == selectedLevel
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = query.isEmpty ||
                entry.category.localizedCaseInsensitiveContains(query) ||
                entry.message.localizedCaseInsensitiveContains(query) ||
                (entry.detail?.localizedCaseInsensitiveContains(query) == true)
            return levelMatches && textMatches
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                if filteredEntries.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.seal",
                        title: store.entries.isEmpty ? "暂无诊断记录" : "没有匹配的记录"
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(filteredEntries) { entry in
                        Button { selectedEntry = entry } label: {
                            entryCard(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索分类或错误信息")
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(entry.level.displayName, systemImage: levelIcon(entry.level))
                            .font(.headline)
                            .foregroundStyle(levelColor(entry.level))
                        LabeledContent("时间", value: entry.date.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("分类", value: entry.category)
                        Text(entry.message)
                            .font(.title3.weight(.semibold))
                        if let detail = entry.detail {
                            Text(detail)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .compatGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("记录详情")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: DiagnosticLogDocument(data: store.exportData()),
            contentType: .json,
            defaultFilename: "Moumusic-diagnostic-logs"
        ) { _ in }
    }

    private var header: some View {
        MouGlassCard(cornerRadius: 24, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("本机诊断", systemImage: "waveform.path.ecg")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    ShareLink(item: String(data: store.exportData(), encoding: .utf8) ?? "[]") {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    Button { isExporting = true } label: {
                        Label("导出", systemImage: "doc")
                    }
                    .buttonStyle(.bordered)
                }
                Text("日志只保存在本机，用于定位播放、搜索和登录问题，不包含 Cookie、Token 或密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Picker("级别", selection: $selectedLevel) {
                        Text("全部").tag("all")
                        ForEach(DiagnosticLogStore.Level.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Button("清空", role: .destructive) { store.clear() }
                        .disabled(store.entries.isEmpty)
                }
            }
        }
    }

    private func entryCard(_ entry: DiagnosticLogStore.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: levelIcon(entry.level))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.message).font(.subheadline.weight(.semibold))
                    Text(entry.category).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func levelIcon(_ level: DiagnosticLogStore.Level) -> String {
        switch level {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func levelColor(_ level: DiagnosticLogStore.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data("[]".utf8)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

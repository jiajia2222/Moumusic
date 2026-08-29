import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @State private var cacheSize = "????"
#if os(iOS)
    @StateObject private var lxStore = LXSourceStore.shared
    @State private var isImportingLX = false
    @State private var lxError: String?
#endif

    var body: some View {
        Form {
            Section("??") {
                Picker("??", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("??? Hi-Res ???????????????")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("??????", isOn: $settings.enableUnblock)
                Text("?????????????? Kumone ????????")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            Section {
                if lxStore.sources.isEmpty {
                    Text(verbatim: "?????????? LX User API ???")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("????", selection: Binding(
                        get: { lxStore.selectedID ?? "" },
                        set: { lxStore.select($0.isEmpty ? nil : $0) }
                    )) {
                        Text(verbatim: "???").tag("")
                        ForEach(lxStore.sources) { source in
                            Text(verbatim: source.name).tag(source.id)
                        }
                    }
                    ForEach(lxStore.sources) { source in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: source.name).font(.body.weight(.medium))
                                let detail = [source.author, source.version]
                                    .filter { !$0.isEmpty }.joined(separator: " ? ")
                                if !detail.isEmpty {
                                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                                }
                                if !source.description.isEmpty {
                                    Text(verbatim: source.description)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                             Button(role: .destructive) { lxStore.remove(source) } label: {
                                 Text(verbatim: "??")
                             }
                                 .font(.caption)
                        }
                    }
                }
                Button {
                    isImportingLX = true
                } label: {
                    Label {
                        Text(verbatim: "?? LX User API")
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                Text(verbatim: "???????????? LX ??? JSON ??? JavaScript ???")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(verbatim: "LX ??")
            } footer: {
                Text(verbatim: "????????????????????????????")
            }
#endif

            Section("??") {
                Picker("??", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
#if os(iOS)
                Picker("?????", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
#endif
                Toggle("??????", isOn: $settings.showLyricsTranslation)
                Toggle("??????? OK?", isOn: $settings.verbatimLyrics)
                Toggle("?????????", isOn: $settings.showLyricsRomaji)
#if os(macOS)
                Toggle("????", isOn: $settings.showDesktopLyrics)
#endif
            }

            Section("??") {
                LabeledContent("????", value: cacheSize)
                Button("????") { clearCache() }
            }

            Section("??") {
                if let profile = account.profile {
                    LabeledContent("????", value: profile.nickname)
                    Button("????", role: .destructive) {
                        Task { await AccountStore.shared.logout() }
                    }
                } else {
                    Text("???").foregroundStyle(.secondary)
                }
            }

            Section("??") {
                Toggle("?????????", isOn: $settings.autoCheckUpdates)
#if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("????", systemImage: "arrow.triangle.2.circlepath")
                }
#endif
            }

            Section("??") {
                LabeledContent("Moumusic", value: appVersion)
                Text("iOS ???? Kumone SwiftUI ?????????????? LX User API ???")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
#if os(macOS)
        .frame(width: 440, height: 520)
#endif
        .task { updateCacheSize() }
#if os(iOS)
        .fileImporter(isPresented: $isImportingLX,
                      allowedContentTypes: [.plainText, .json, .sourceCode,
                                            UTType(filenameExtension: "js") ?? .plainText]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try lxStore.importScript(data, suggestedName: url.deletingPathExtension().lastPathComponent)
                LXUserAPIService.shared.loadSelectedSource()
            } catch {
                lxError = error.localizedDescription
            }
        }
        .alert("LX ??", isPresented: Binding(
            get: { lxError != nil },
            set: { if !$0 { lxError = nil } }
        )) {
            Button("??", role: .cancel) { lxError = nil }
        } message: {
            Text(lxError ?? "????")
        }
#endif
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
    }

    private func updateCacheSize() {
        let directory = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let bytes = files.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            DispatchQueue.main.async { cacheSize = formatted }
        }
    }

    private func clearCache() {
        let directory = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                cacheSize = "0 ??"
                ToastCenter.shared.show("?????")
            }
        }
    }
}

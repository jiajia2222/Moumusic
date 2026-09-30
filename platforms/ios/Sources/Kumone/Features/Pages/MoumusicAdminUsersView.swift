#if os(iOS)
import SwiftUI

/// Server-side profile management. Provider cookies and music data remain
/// outside this screen; the administrator only manages Moumusic identity
/// cards and the account availability flag.
struct MoumusicAdminUsersView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var server: MoumusicServerStore
    @State private var users: [MoumusicServerStore.Profile] = []
    @State private var isLoading = false
    @State private var editingUser: MoumusicServerStore.Profile?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && users.isEmpty {
                    ProgressView("Loading profiles…")
                } else if users.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView("No user profiles", systemImage: "person.2.slash")
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "person.2.slash")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                            Text("No user profiles")
                                .font(.headline)
                            Text("Managed profiles will appear here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    }
                } else {
                    List {
                        Section("Managed profiles") {
                            ForEach(users.filter { !$0.isAdmin }) { user in
                                Button {
                                    editingUser = user
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: user.disabled == true ? "person.slash" : "person.crop.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(user.disabled == true ? .secondary : Theme.accent)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(user.nickname)
                                                .foregroundStyle(.primary)
                                            Text("ID: \(user.id)")
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                            if user.disabled == true {
                                                Text("Disabled")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.red)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("用户管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task { await reload() }
            .sheet(item: $editingUser) { user in
                MoumusicAdminUserEditor(user: user)
                    .environmentObject(server)
                    .onDisappear {
                        Task { await reload() }
                    }
            }
        }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        users = await server.loadManagedUsers()
        isLoading = false
    }
}

private struct MoumusicAdminUserEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var server: MoumusicServerStore
    let user: MoumusicServerStore.Profile
    @State private var publicID: String
    @State private var nickname: String
    @State private var avatarURL: String
    @State private var signature: String
    @State private var disabled: Bool
    @State private var isSaving = false

    init(user: MoumusicServerStore.Profile) {
        self.user = user
        _publicID = State(initialValue: user.id)
        _nickname = State(initialValue: user.nickname)
        _avatarURL = State(initialValue: user.avatarURL ?? "")
        _signature = State(initialValue: user.signature ?? "")
        _disabled = State(initialValue: user.disabled == true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile ID") {
                    TextField("Unique ID", text: $publicID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("3–32 characters: letters, numbers, dot, underscore, or hyphen. IDs are case-insensitive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Profile card") {
                    TextField("Nickname", text: $nickname)
                    TextField("Avatar URL", text: $avatarURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Signature", text: $signature, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Toggle("Disable this account", isOn: $disabled)
                }
                if let error = server.lastError, !error.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑资料卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("保存") }
                    }
                    .disabled(isSaving || publicID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        let success = await server.updateManagedUser(
            id: user.id,
            publicID: publicID,
            nickname: nickname,
            avatarURL: avatarURL,
            signature: signature,
            disabled: disabled
        )
        isSaving = false
        if success { dismiss() }
    }
}
#endif

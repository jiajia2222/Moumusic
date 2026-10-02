#if os(iOS)
import SwiftUI

struct MoumusicAdminLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var server: MoumusicServerStore
    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Administrator") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    if let error = server.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        isSubmitting = true
                        Task {
                            let success = await server.adminLogin(username: username, password: password)
                            isSubmitting = false
                            if success { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView() }
                            Text("Sign in")
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || username.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Server access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif

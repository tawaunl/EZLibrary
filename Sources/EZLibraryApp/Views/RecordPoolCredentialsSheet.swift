import SwiftUI
import EZLibraryCore

/// Sign-in sheet for DJ record pools. Credentials are stored only in the macOS
/// Keychain (via `RecordPoolCredentialStore`) — never in defaults and never
/// logged. Each pool can be connected or removed independently.
struct RecordPoolCredentialsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when credentials change so the caller can refresh which pools are
    /// configured and re-run searches.
    let onCredentialsChanged: () -> Void

    private let store = RecordPoolCredentialStore()

    @State private var usernameByPool: [RecordPool: String] = [:]
    @State private var passwordByPool: [RecordPool: String] = [:]
    @State private var connectedPools: Set<RecordPool> = []
    @State private var statusByPool: [RecordPool: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record Pools")
                    .font(.title2.weight(.semibold))
                Text("Sign in with your own subscription to search these pools in-app. Your credentials are stored securely in the macOS Keychain and are only sent to the pool over HTTPS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(RecordPool.allCases) { pool in
                poolCard(pool)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadExisting)
    }

    @ViewBuilder
    private func poolCard(_ pool: RecordPool) -> some View {
        let isConnected = connectedPools.contains(pool)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(pool.displayName)
                    .font(.headline)
                if isConnected {
                    Label("Connected", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.open(pool.homeURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open \(pool.displayName) in your browser.")
            }

            TextField("Email or username", text: bindingForUsername(pool))
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)

            SecureField(isConnected ? "Password (saved — leave blank to keep)" : "Password", text: bindingForPassword(pool))
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit { save(pool) }

            HStack(spacing: 8) {
                Button(isConnected ? "Update" : "Connect") {
                    save(pool)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled((usernameByPool[pool] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)

                if isConnected {
                    Button("Remove") {
                        remove(pool)
                    }
                    .controlSize(.small)
                    .help("Delete the saved credentials for \(pool.displayName) from the Keychain.")
                }

                Spacer(minLength: 0)

                if let status = statusByPool[pool] {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func bindingForUsername(_ pool: RecordPool) -> Binding<String> {
        Binding(
            get: { usernameByPool[pool] ?? "" },
            set: { usernameByPool[pool] = $0 }
        )
    }

    private func bindingForPassword(_ pool: RecordPool) -> Binding<String> {
        Binding(
            get: { passwordByPool[pool] ?? "" },
            set: { passwordByPool[pool] = $0 }
        )
    }

    private func loadExisting() {
        for pool in RecordPool.allCases {
            if let credentials = try? store.credentials(for: pool) {
                usernameByPool[pool] = credentials.username
                connectedPools.insert(pool)
            }
        }
    }

    private func save(_ pool: RecordPool) {
        let username = (usernameByPool[pool] ?? "").trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { return }

        // Keep the existing password when the field is left blank on an update.
        let typedPassword = passwordByPool[pool] ?? ""
        let password: String
        if typedPassword.isEmpty, let existing = try? store.credentials(for: pool) {
            password = existing.password
        } else {
            password = typedPassword
        }

        guard !password.isEmpty else {
            statusByPool[pool] = "Enter your password to connect."
            return
        }

        do {
            try store.save(RecordPoolCredentials(username: username, password: password), for: pool)
            connectedPools.insert(pool)
            passwordByPool[pool] = ""
            statusByPool[pool] = "Saved."
            onCredentialsChanged()
        } catch {
            statusByPool[pool] = error.localizedDescription
        }
    }

    private func remove(_ pool: RecordPool) {
        do {
            try store.remove(for: pool)
            connectedPools.remove(pool)
            usernameByPool[pool] = ""
            passwordByPool[pool] = ""
            statusByPool[pool] = "Removed."
            onCredentialsChanged()
        } catch {
            statusByPool[pool] = error.localizedDescription
        }
    }
}

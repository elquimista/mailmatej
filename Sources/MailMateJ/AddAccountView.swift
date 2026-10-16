import JMAPKit
import MailStore
import SwiftUI

struct AddAccountView: View {
    enum Provider: String, CaseIterable, Identifiable {
        case fastmail = "Fastmail"
        case jmap = "Stalwart / other JMAP server"
        var id: String { rawValue }
    }

    let onAdd: @MainActor (AccountDraft) async throws -> Void
    let onCancel: @MainActor () -> Void

    @State private var provider = Provider.jmap
    @State private var server = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var name = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account").font(.headline)
            // Column style sizes to its content; the grouped style is a scroll view that collapses in a sheet.
            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                }
                switch provider {
                case .fastmail:
                    SecureField("API token", text: $secret)
                    Text("Create one in Fastmail → Settings → Privacy & Security → Manage API tokens, with Email access (read-only is enough for now).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .jmap:
                    TextField("Server", text: $server, prompt: Text("mail.example.com"))
                    TextField("Username", text: $username, prompt: Text("you@example.com"))
                    SecureField("Password", text: $secret)
                }
                TextField("Account name", text: $name, prompt: Text("Optional"))
            }
            .formStyle(.columns)
            .disabled(isWorking)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Account") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !isComplete)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var isComplete: Bool {
        switch provider {
        case .fastmail: !secret.isEmpty
        case .jmap: !server.isEmpty && !username.isEmpty && !secret.isEmpty
        }
    }

    private func submit() {
        let draft: AccountDraft
        switch provider {
        case .fastmail:
            draft = AccountDraft(
                name: name, sessionURL: URL(string: "https://api.fastmail.com/jmap/session")!, username: "",
                authKind: .bearer, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
        case .jmap:
            guard let url = JMAPClient.sessionURL(from: server) else {
                error = "That doesn’t look like a server address."
                return
            }
            draft = AccountDraft(
                name: name, sessionURL: url, username: username.trimmingCharacters(in: .whitespaces),
                authKind: .basic, secret: secret)
        }
        isWorking = true
        error = nil
        Task {
            do {
                try await onAdd(draft)
            } catch {
                self.error = AppModel.describe(error)
            }
            isWorking = false
        }
    }
}

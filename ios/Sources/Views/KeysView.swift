import SwiftUI

struct KeysView: View {
    @EnvironmentObject var inboxStore: InboxStore

    var body: some View {
        List {
            Section("Identity key (transport)") {
                keyRow(inboxStore.ownPublicKeyBase64)
            }
            Section("Biometric signing key") {
                if let biometricPublicKeyBase64 = inboxStore.biometricPublicKeyBase64 {
                    keyRow(biometricPublicKeyBase64)
                    Text("Register on the sender in peer_configs/<name>.json as biometric_public_key to require biometric signatures.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Enable biometric signing") {
                        inboxStore.createBiometricKey()
                    }
                    Text("Creates a P-256 key inside the Secure Enclave. Answers gain a hardware signature gated by Face ID; the key can never leave the enclave.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let statusMessage = inboxStore.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Keys")
    }

    @ViewBuilder private func keyRow(_ publicKeyBase64: String?) -> some View {
        if let publicKeyBase64 {
            Text(publicKeyBase64)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button("Copy") {
                UIPasteboard.general.string = publicKeyBase64
            }
        } else {
            Text("Not created yet")
                .foregroundStyle(.secondary)
        }
    }
}

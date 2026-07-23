import CoreImage.CIFilterBuiltins
import SwiftUI

struct EnrollmentView: View {
    @EnvironmentObject var inboxStore: InboxStore
    @State private var peerInput = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if inboxStore.enrollmentPhase == .needsIdentity {
                    identitySection
                } else {
                    pairingSection
                }
                if let statusMessage = inboxStore.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Enrollment")
    }

    private var identitySection: some View {
        VStack(spacing: 16) {
            Image(systemName: "faceid")
                .font(.system(size: 56))
            Text("Create your signing identity. The key is protected by Face ID and never leaves this device.")
                .multilineTextAlignment(.center)
            Button("Create identity") {
                inboxStore.createIdentity()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var pairingSection: some View {
        VStack(spacing: 16) {
            Text("Your public key")
                .font(.headline)
            if let ownQrImage {
                Image(uiImage: ownQrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
            }
            if let ownPublicKeyBase64 = inboxStore.ownPublicKeyBase64 {
                Text(ownPublicKeyBase64)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("Copy public key") {
                    UIPasteboard.general.string = ownPublicKeyBase64
                }
                .buttonStyle(.bordered)
            }
            Divider()
            Text("Paste the agent's public key")
                .font(.headline)
            TextField("Base64 public key", text: $peerInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Pair") {
                Task { await inboxStore.savePeer(input: peerInput) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(peerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var ownQrImage: UIImage? {
        guard let ownPublicKeyBase64 = inboxStore.ownPublicKeyBase64 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(ownPublicKeyBase64.utf8)
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

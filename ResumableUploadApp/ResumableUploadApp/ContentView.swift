import SwiftUI

struct ContentView: View {
    @ObservedObject var store: UploadStore
    @AppStorage("uploadEndpoint") private var uploadEndpoint = "https://annie-uninitialled-untractably.ngrok-free.dev/files"
    @AppStorage("uploadAuthToken") private var uploadAuthToken = "019d0ab9-c19b-785c-82ab-209fce9b2eb0"

    @State private var isPresentingPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.97, blue: 1.0),
                        Color(red: 0.90, green: 0.94, blue: 0.98),
                        Color(red: 0.98, green: 0.93, blue: 0.89)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heroCard
                        endpointCard
                        uploadsSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Resumable Upload")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $isPresentingPicker) {
            VideoPicker { result in
                switch result {
                case .success(let pickedVideo):
                    Task {
                        await store.importPickedVideo(
                            from: pickedVideo.url,
                            suggestedFileName: pickedVideo.suggestedFileName,
                            endpointString: uploadEndpoint,
                            authToken: uploadAuthToken
                        )
                    }
                case .failure(let error):
                    store.messageBanner = error.localizedDescription
                }
            }
        }
        .alert("Upload Status", isPresented: bannerBinding) {
            Button("OK", role: .cancel) {
                store.messageBanner = nil
            }
        } message: {
            Text(store.messageBanner ?? "")
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background video uploads that keep going.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.28))

            Text("Pick a video, let iOS keep pushing in a background session, and pause or resume when you need to.")
                .font(.body)
                .foregroundStyle(.secondary)

            Button {
                isPresentingPicker = true
            } label: {
                HStack {
                    Image(systemName: "video.badge.plus")
                    Text(store.isImporting ? "Preparing Video..." : "Choose Video")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(red: 0.16, green: 0.38, blue: 0.73))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(store.isImporting)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var endpointCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upload Endpoint")
                .font(.headline)

            TextField("https://example.com/upload", text: $uploadEndpoint)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            SecureField("Bearer token", text: $uploadAuthToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("New uploads send `Authorization: Bearer <token>` when a token is provided. Use a backend that supports Apple's resumable-upload flow for pause/resume and automatic recovery.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uploads")
                .font(.title3.weight(.semibold))

            if store.uploads.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No uploads yet")
                        .font(.headline)
                    Text("Pick a video to create a staged background upload task.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ForEach(store.uploads) { upload in
                    UploadCard(
                        upload: upload,
                        pauseAction: { store.pauseUpload(id: upload.id) },
                        resumeAction: { store.resumeUpload(id: upload.id) },
                        cancelAction: { store.cancelUpload(id: upload.id) }
                    )
                }
            }
        }
    }

    private var bannerBinding: Binding<Bool> {
        Binding(
            get: { store.messageBanner != nil },
            set: { isPresented in
                if isPresented == false {
                    store.messageBanner = nil
                }
            }
        )
    }
}

private struct UploadCard: View {
    let upload: UploadRecord
    let pauseAction: () -> Void
    let resumeAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(upload.fileName)
                        .font(.headline)
                        .lineLimit(2)

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Text(byteProgressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: upload.progressFraction)
                .tint(statusColor)

            if let errorDescription = upload.errorDescription, upload.state == .failed {
                Text(errorDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if upload.state == .uploading {
                    actionButton("Pause", tint: Color.orange.opacity(0.15), foreground: .orange, action: pauseAction)
                }

                if upload.canResume {
                    actionButton("Resume", tint: Color.blue.opacity(0.14), foreground: .blue, action: resumeAction)
                }

                if upload.state == .uploading || upload.state == .paused || upload.state == .queued || upload.state == .failed {
                    actionButton("Cancel", tint: Color.red.opacity(0.14), foreground: .red, action: cancelAction)
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func actionButton(_ title: String, tint: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(tint, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var statusText: String {
        switch upload.state {
        case .queued:
            return "Queued"
        case .uploading:
            return "Uploading"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        }
    }

    private var statusColor: Color {
        switch upload.state {
        case .queued:
            return .gray
        case .uploading:
            return Color(red: 0.16, green: 0.38, blue: 0.73)
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .secondary
        }
    }

    private var byteProgressText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let sent = formatter.string(fromByteCount: upload.bytesSent)
        let expectedBase = upload.expectedBytes > 0 ? upload.expectedBytes : upload.fileSize
        let total = formatter.string(fromByteCount: expectedBase)

        if let fraction = upload.progressFraction {
            let percent = Int((fraction * 100).rounded())
            return "\(percent)% • \(sent) / \(total)"
        }

        return "\(sent) / \(total)"
    }
}

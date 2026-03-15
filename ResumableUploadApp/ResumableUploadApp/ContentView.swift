import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var uploadManager: UploadManager
    @State private var selectedItem: PhotosPickerItem?
    @State private var serverURL: String = "https://5639-77-207-91-127.ngrok-free.app"
    @State private var chunkSizeMB: Double = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Configuration") {
                    VStack(alignment: .leading) {
                        Text("Chunk Size: \(Int(chunkSizeMB)) MB")
                        Slider(value: $chunkSizeMB, in: 1...100, step: 1) {
                            Text("Chunk Size")
                        }
                    }
                }

                Section("File") {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label(
                            uploadManager.selectedFileName ?? "Select Video",
                            systemImage: "video.fill"
                        )
                    }
                    .onChange(of: selectedItem) { _, newItem in
                        guard let newItem else { return }
                        Task {
                            await uploadManager.loadVideo(from: newItem)
                        }
                    }

                    if let size = uploadManager.totalBytes, size > 0 {
                        Text("Size: \(formatBytes(size))")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Controls") {
                    HStack(spacing: 16) {
                        Button("Upload") {
                            uploadManager.startUpload(
                                serverURL: serverURL,
                                chunkSizeMB: Int(chunkSizeMB)
                            )
                        }
                        .disabled(!uploadManager.canStart)

                        Button("Pause") {
                            uploadManager.pause()
                        }
                        .disabled(!uploadManager.canPause)

                        Button("Resume") {
                            uploadManager.resume()
                        }
                        .disabled(!uploadManager.canResume)

                        Button("Cancel") {
                            uploadManager.cancel()
                        }
                        .disabled(!uploadManager.canCancel)
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                }

                Section("Progress") {
                    ProgressView(value: uploadManager.progress)
                        .progressViewStyle(.linear)

                    LabeledContent("Status", value: uploadManager.state.displayName)
                    LabeledContent("Uploaded", value: formatBytes(uploadManager.bytesUploaded))
                    if let total = uploadManager.totalBytes {
                        LabeledContent("Total", value: formatBytes(total))
                    }
                    LabeledContent("Speed", value: uploadManager.speedDisplay)
                    LabeledContent("Offset", value: "\(uploadManager.currentOffset)")
                    LabeledContent("Connection", value: uploadManager.connectionInfo)
                }

                if let error = uploadManager.errorMessage {
                    Section("Error") {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Resumable Upload")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}

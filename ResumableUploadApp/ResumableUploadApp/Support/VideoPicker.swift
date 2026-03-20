import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PickedVideo {
    let url: URL
    let suggestedFileName: String
}

struct VideoPicker: UIViewControllerRepresentable {
    let onPick: @MainActor (Result<PickedVideo, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: @MainActor (Result<PickedVideo, Error>) -> Void

        init(onPick: @escaping @MainActor (Result<PickedVideo, Error>) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let result = results.first else {
                return
            }

            let provider = result.itemProvider
            let suggestedName = provider.suggestedName
            let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .movie) == true
            }) ?? UTType.movie.identifier

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
                if let error {
                    Task { @MainActor in
                        self.onPick(.failure(error))
                    }
                    return
                }

                guard let sourceURL else {
                    Task { @MainActor in
                        self.onPick(.failure(VideoPickerError.noVideoReturned))
                    }
                    return
                }

                do {
                    let extensionName = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(extensionName)

                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try FileManager.default.removeItem(at: tempURL)
                    }

                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                    let fileName = suggestedName ?? tempURL.lastPathComponent

                    Task { @MainActor in
                        self.onPick(.success(PickedVideo(url: tempURL, suggestedFileName: fileName)))
                    }
                } catch {
                    Task { @MainActor in
                        self.onPick(.failure(error))
                    }
                }
            }
        }
    }
}

enum VideoPickerError: LocalizedError {
    case noVideoReturned

    var errorDescription: String? {
        switch self {
        case .noVideoReturned:
            return "The picker did not return a usable video file."
        }
    }
}

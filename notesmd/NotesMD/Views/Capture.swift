import AVFoundation
import ImageIO
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Records audio into a note, AAC in an `.m4a` file as on the phone.
@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var url: URL?

    static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording \(formatter.string(from: date)).m4a"
    }

    func start() async -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        #else
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(Self.fileName())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else { return false }
        self.recorder = recorder
        self.url = url
        recording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
        return true
    }

    /// Stops; the file when it is kept.
    func stop(keep: Bool) -> URL? {
        recorder?.stop()
        timer?.invalidate()
        recording = false
        recorder = nil
        guard keep, let url else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return url
    }
}

struct RecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = Recorder()
    let onDone: (URL) -> Void
    @State private var failed = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.orange)
            Text(recorder.recording ? "● " + time(recorder.elapsed) : (failed ? "Recording is not allowed" : "Starting…"))
                .font(.title2.monospacedDigit())
                .foregroundStyle(recorder.recording ? .red : .secondary)
            HStack(spacing: 16) {
                Button("Cancel", role: .cancel) {
                    _ = recorder.stop(keep: false)
                    dismiss()
                }
                Button("Stop and Keep") {
                    if let url = recorder.stop(keep: true) { onDone(url) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!recorder.recording)
            }
        }
        .padding(32)
        .frame(minWidth: 320, minHeight: 240)
        .task { failed = !(await recorder.start()) }
        .presentationDetents([.medium])
    }

    private func time(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

#if os(iOS)
/// The camera, for a photo straight into the note.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif

/// A picture as the phone keeps one: JPEG, quality 88, at most 2048 pixels on its long side.
enum PictureFiles {
    static func jpeg(_ data: Data) -> URL? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}

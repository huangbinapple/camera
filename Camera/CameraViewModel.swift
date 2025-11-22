import SwiftUI
import AVFoundation
import Combine
import Photos

final class CameraViewModel: NSObject, ObservableObject {
    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var lastCapturedImage: UIImage?
    @Published var photoAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @Published var savingMessage: String?
    @Published var lastSavedAssetLocalIdentifier: String?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private var isSessionConfigured = false

    override init() {
        super.init()
    }

    func checkPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }

        switch status {
        case .authorized:
            startSession()
        case .notDetermined:
            requestAccess()
        case .denied, .restricted:
            stopSession()
        @unknown default:
            stopSession()
        }
    }

    private func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            let newStatus: AVAuthorizationStatus = granted ? .authorized : .denied
            DispatchQueue.main.async {
                self.authorizationStatus = newStatus
            }
            if granted {
                self.startSession()
            }
        }
    }

    func startSession() {
        guard authorizationStatus == .authorized else { return }
        sessionQueue.async {
            if !self.isSessionConfigured {
                self.configureSession()
            }
            guard self.isSessionConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Remove existing inputs
        session.inputs.forEach { input in
            session.removeInput(input)
        }

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
        } catch {
            session.commitConfiguration()
            return
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.isHighResolutionCaptureEnabled = true
        }

        session.commitConfiguration()
        isSessionConfigured = true
    }

    func capturePhoto() {
        guard authorizationStatus == .authorized, isSessionConfigured else { return }
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = photoOutput.isHighResolutionCaptureEnabled
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func requestPhotoLibraryAccess(completion: @escaping (PHAuthorizationStatus) -> Void) {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if currentStatus == .authorized || currentStatus == .limited {
            DispatchQueue.main.async {
                self.photoAuthorizationStatus = currentStatus
                completion(currentStatus)
            }
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                self.photoAuthorizationStatus = status
                completion(status)
            }
        }
    }

    private func saveImageToPhotoLibrary(_ image: UIImage) {
        requestPhotoLibraryAccess { status in
            guard status == .authorized || status == .limited else {
                self.savingMessage = "Photo Library access is denied."
                return
            }

            var placeholderIdentifier: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                request.creationDate = Date()
                placeholderIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.savingMessage = nil
                        self.lastSavedAssetLocalIdentifier = placeholderIdentifier
                    } else if let error = error {
                        self.savingMessage = "Failed to save photo: \(error.localizedDescription)"
                        print("Photo save error: \(error)")
                    } else {
                        self.savingMessage = "Failed to save photo."
                    }
                }
            })
        }
    }

    func photosDeepLinkURLs() -> (asset: URL?, fallback: URL?) {
        let assetURL: URL? = lastSavedAssetLocalIdentifier.flatMap { identifier in
            URL(string: "photos-redirect://\(identifier)")
        }
        let fallbackURL = URL(string: "photos-redirect://")
        return (assetURL, fallbackURL)
    }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        DispatchQueue.main.async {
            self.lastCapturedImage = image
        }
        saveImageToPhotoLibrary(image)
    }
}

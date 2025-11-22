import SwiftUI
import AVFoundation
import Combine
import Photos
import UIKit
import CoreImage

final class CameraViewModel: NSObject, ObservableObject {
    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var lastCapturedImage: UIImage?
    @Published var currentPreviewImage: UIImage?
    @Published var photoAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @Published var savingMessage: String?
    @Published var lastSavedAssetLocalIdentifier: String?
    @Published var availableLUTs: [LUTFilter] = []
    @Published var selectedLUT: LUTFilter?
    @Published var lutStatusMessage: String?
    @Published var previewAspectRatio: CGFloat = 3.0 / 4.0
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var currentFlashMode: FlashMode = .auto
    @Published var currentCameraPosition: AVCaptureDevice.Position = .back
    @Published var currentMode: CameraMode = .photo
    @Published var focusPoint: CGPoint?
    @Published var isShowingFocusIndicator: Bool = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "camera.video.output.queue")
    private let ciContext = CIContext()
    private var isSessionConfigured = false
    private let videoOrientation: AVCaptureVideoOrientation = .portrait
    private var minZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat = 3.0
    private var currentVideoDevice: AVCaptureDevice?

    enum FlashMode: CaseIterable {
        case auto
        case on
        case off

        var next: FlashMode {
            switch self {
            case .auto: return .on
            case .on: return .off
            case .off: return .auto
            }
        }

        var captureFlashMode: AVCaptureDevice.FlashMode {
            switch self {
            case .auto: return .auto
            case .on: return .on
            case .off: return .off
            }
        }

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .on: return "On"
            case .off: return "Off"
            }
        }

        var icon: String {
            switch self {
            case .auto: return "⚡︎ Auto"
            case .on: return "⚡︎ On"
            case .off: return "⚡︎ Off"
            }
        }
    }

    enum CameraMode: String, CaseIterable {
        case video = "视频"
        case photo = "照片"
        case portrait = "人像"
    }

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

    func importLUT(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let lut = try self.parseCubeLUT(from: url)
                DispatchQueue.main.async {
                    self.availableLUTs.append(lut)
                    self.selectedLUT = lut
                    self.lutStatusMessage = "Imported LUT: \(lut.name)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.lutStatusMessage = "Failed to import LUT: \(error.localizedDescription)"
                }
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

    func switchCamera() {
        sessionQueue.async {
            self.currentCameraPosition = self.currentCameraPosition == .back ? .front : .back
            self.isSessionConfigured = false
            self.configureSession()
            if self.isSessionConfigured, !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func cycleFlashMode() {
        DispatchQueue.main.async {
            self.currentFlashMode = self.currentFlashMode.next
        }
    }

    func setZoom(to factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.currentVideoDevice else { return }
            let clamped = min(max(factor, self.minZoomFactor), self.maxZoomFactor)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.currentZoomFactor = clamped
                }
            } catch {
                print("Failed to set zoom: \(error)")
            }
        }
    }

    func setZoomPreset(_ factor: CGFloat) {
        setZoom(to: factor)
    }

    func focus(at point: CGPoint, frameSize: CGSize) {
        sessionQueue.async {
            guard let device = self.currentVideoDevice else { return }
            let normalizedPoint = CGPoint(x: point.y / frameSize.height, y: 1.0 - (point.x / frameSize.width))
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = normalizedPoint
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = normalizedPoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {
                print("Failed to focus: \(error)")
            }
        }

        DispatchQueue.main.async {
            self.focusPoint = point
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isShowingFocusIndicator = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.isShowingFocusIndicator = false
                }
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

        guard let videoDevice = selectVideoDevice(position: currentCameraPosition) else {
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

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
            videoOutput.connections.forEach { connection in
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = videoOrientation
                }
            }
        }

        session.commitConfiguration()
        isSessionConfigured = true

        currentVideoDevice = videoDevice
        updateZoomLimits(for: videoDevice)
        setZoom(to: currentZoomFactor)

        let formatDescription = videoDevice.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let aspect = videoOrientation == .portrait || videoOrientation == .portraitUpsideDown
            ? CGFloat(dimensions.height) / CGFloat(dimensions.width)
            : CGFloat(dimensions.width) / CGFloat(dimensions.height)
        DispatchQueue.main.async {
            self.previewAspectRatio = aspect
        }
    }

    func capturePhoto() {
        guard authorizationStatus == .authorized, isSessionConfigured else { return }
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = photoOutput.isHighResolutionCaptureEnabled
        if photoOutput.supportedFlashModes.contains(currentFlashMode.captureFlashMode) {
            settings.flashMode = currentFlashMode.captureFlashMode
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
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
                if let placeholder = request.placeholderForCreatedAsset {
                    placeholderIdentifier = placeholder.localIdentifier
                }
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.lastSavedAssetLocalIdentifier = placeholderIdentifier
                        self.savingMessage = nil
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

    func openLastSavedPhoto() {
        func openURL(_ url: URL) {
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }

        if let identifier = lastSavedAssetLocalIdentifier,
           let assetURL = URL(string: "photos-redirect://?assetIdentifier=\(identifier)"),
           UIApplication.shared.canOpenURL(assetURL) {
            openURL(assetURL)
            return
        }

        if let fallbackURL = URL(string: "photos-redirect://"), UIApplication.shared.canOpenURL(fallbackURL) {
            openURL(fallbackURL)
        }
    }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        let selectedLUT = self.selectedLUT
        DispatchQueue.global(qos: .userInitiated).async {
            let processedImage: UIImage

            if let lut = selectedLUT, let filtered = self.applyLUT(to: image, lut: lut) {
                processedImage = filtered
            } else {
                processedImage = image
            }

            DispatchQueue.main.async {
                self.lastCapturedImage = processedImage
            }
            self.saveImageToPhotoLibrary(processedImage)
        }
    }
}

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let processedImage: CIImage

        if let lut = selectedLUT, let filtered = applyLUT(to: ciImage, lut: lut) {
            processedImage = filtered
        } else {
            processedImage = ciImage
        }

        guard let cgImage = ciContext.createCGImage(processedImage, from: processedImage.extent) else {
            print("Failed to create CGImage for preview frame")
            return
        }

        let uiImage = UIImage(cgImage: cgImage)
        DispatchQueue.main.async {
            self.currentPreviewImage = uiImage
        }
    }
}

private extension CameraViewModel {
    enum LUTParserError: LocalizedError {
        case invalidFormat
        case missingSize
        case invalidDataCount

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Invalid LUT format."
            case .missingSize:
                return "LUT size is missing."
            case .invalidDataCount:
                return "LUT data count does not match the expected size."
            }
        }
    }

    func parseCubeLUT(from url: URL) throws -> LUTFilter {
        let content = try String(contentsOf: url)
        let lines = content.components(separatedBy: .newlines)

        var size: Int?
        var values: [Float] = []

        let numberFormatter = NumberFormatter()
        numberFormatter.decimalSeparator = "."

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                let parts = line.components(separatedBy: .whitespaces).compactMap { Int($0) }
                if let dimension = parts.last {
                    size = dimension
                }
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count == 3 else { continue }

            let rgb = components.compactMap { numberFormatter.number(from: $0)?.floatValue }
            guard rgb.count == 3 else { throw LUTParserError.invalidFormat }
            values.append(contentsOf: rgb)
        }

        guard let cubeSize = size else { throw LUTParserError.missingSize }

        let expectedValueCount = cubeSize * cubeSize * cubeSize * 3
        guard values.count == expectedValueCount else { throw LUTParserError.invalidDataCount }

        var cubeData = Data(capacity: cubeSize * cubeSize * cubeSize * 4 * MemoryLayout<Float>.size)
        for index in stride(from: 0, to: values.count, by: 3) {
            var r = values[index]
            var g = values[index + 1]
            var b = values[index + 2]
            var a: Float = 1.0
            withUnsafeBytes(of: &r) { cubeData.append(contentsOf: $0) }
            withUnsafeBytes(of: &g) { cubeData.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { cubeData.append(contentsOf: $0) }
            withUnsafeBytes(of: &a) { cubeData.append(contentsOf: $0) }
        }

        let name = url.deletingPathExtension().lastPathComponent
        return LUTFilter(name: name, cubeSize: cubeSize, cubeData: cubeData)
    }

    func applyLUT(to image: UIImage, lut: LUTFilter) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let inputImage = CIImage(cgImage: cgImage)

        guard let filtered = applyLUT(to: inputImage, lut: lut),
              let outputCGImage = ciContext.createCGImage(filtered, from: filtered.extent) else {
            return nil
        }

        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    func applyLUT(to ciImage: CIImage, lut: LUTFilter) -> CIImage? {
        guard let filter = CIFilter(name: "CIColorCube") else {
            print("Failed to create CIColorCube filter")
            return nil
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(lut.cubeSize, forKey: "inputCubeDimension")
        filter.setValue(lut.cubeData, forKey: "inputCubeData")
        guard let output = filter.outputImage else {
            print("CIColorCube failed to produce output image")
            return nil
        }
        return output
    }

    func selectVideoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
    }

    func updateZoomLimits(for device: AVCaptureDevice) {
        minZoomFactor = max(1.0, device.minAvailableVideoZoomFactor)
        maxZoomFactor = min(3.0, device.maxAvailableVideoZoomFactor)
        DispatchQueue.main.async {
            self.currentZoomFactor = min(max(self.currentZoomFactor, self.minZoomFactor), self.maxZoomFactor)
        }
    }
}

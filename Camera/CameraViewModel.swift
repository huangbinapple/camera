import SwiftUI
import AVFoundation
import Combine
import Photos
import UIKit
import CoreImage
import simd

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
    @Published var flashMode: FlashMode = .auto
    @Published var currentCameraPosition: AVCaptureDevice.Position = .back
    @Published var currentMode: CameraMode = .photo
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var minZoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 3.0

    var isFrontCamera: Bool { currentCameraPosition == .front }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "camera.video.output.queue")
    private let ciContext = CIContext()
    private var isSessionConfigured = false
    private let videoOrientation: AVCaptureVideoOrientation = .portrait
    private var videoDevice: AVCaptureDevice?

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

    var zoomPresets: [CGFloat] {
        let presets: [CGFloat] = [0.5, 1.0, 2.0, 3.0]
        return presets.filter { $0 >= minZoomFactor && $0 <= maxZoomFactor + 0.01 }
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
                    self.selectedLUT = nil
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

    func cycleFlashMode() {
        DispatchQueue.main.async {
            self.flashMode = self.flashMode.next
        }
    }

    func switchCamera() {
        sessionQueue.async {
            let newPosition: AVCaptureDevice.Position = self.currentCameraPosition == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.inputs.forEach { input in
                    self.session.removeInput(input)
                }
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                }
                if !self.session.outputs.contains(self.photoOutput), self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }
                if !self.session.outputs.contains(self.videoOutput), self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                }
                self.updateConnectionsOrientation()
                self.session.commitConfiguration()

                self.videoDevice = device
                self.updateZoomLimits(for: device)
                self.updatePreviewAspectRatio(for: device)
                DispatchQueue.main.async {
                    self.currentCameraPosition = newPosition
                    self.currentZoomFactor = self.minZoomFactor
                    self.currentPreviewImage = nil
                }
            } catch {
                print("Failed to switch camera: \(error)")
            }
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        let clamped = max(minZoomFactor, min(factor, maxZoomFactor))
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
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

    func focus(at normalizedPoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            let focusPoint = normalizedPoint
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = focusPoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = focusPoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                print("Failed to focus: \(error)")
            }
        }
    }

    func setMode(_ mode: CameraMode) {
        DispatchQueue.main.async {
            self.currentMode = mode
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

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCameraPosition) else {
            session.commitConfiguration()
            return
        }

        self.videoDevice = videoDevice

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

        updateConnectionsOrientation()

        session.commitConfiguration()
        isSessionConfigured = true

        updateZoomLimits(for: videoDevice)
        updatePreviewAspectRatio(for: videoDevice)
    }

    func capturePhoto() {
        guard authorizationStatus == .authorized, isSessionConfigured else { return }
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = photoOutput.isHighResolutionCaptureEnabled
        let desiredFlashMode = flashMode.asAVCaptureFlashMode
        if photoOutput.supportedFlashModes.contains(desiredFlashMode) {
            settings.flashMode = desiredFlashMode
        } else if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
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

enum FlashMode: CaseIterable {
    case auto
    case on
    case off

    var displaySymbol: String {
        switch self {
        case .auto: return "A"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    var next: FlashMode {
        switch self {
        case .auto: return .on
        case .on: return .off
        case .off: return .auto
        }
    }

    var asAVCaptureFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: return .auto
        case .on: return .on
        case .off: return .off
        }
    }
}

enum CameraMode: String, CaseIterable {
    case video = "视频"
    case photo = "照片"
    case portrait = "人像"

    var displayName: String { rawValue }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let cgImage = UIImage(data: data)?.cgImage else { return }
        let selectedLUT = self.selectedLUT

        DispatchQueue.global(qos: .userInitiated).async {
            let inputImage = CIImage(cgImage: cgImage)
            let lutAppliedImage = selectedLUT.flatMap { self.applyLUT(to: inputImage, lut: $0) } ?? inputImage
            let finalCIImage = self.mirroredIfNeeded(lutAppliedImage)

            guard let outputCGImage = self.ciContext.createCGImage(finalCIImage, from: finalCIImage.extent) else { return }
            let processedImage = UIImage(cgImage: outputCGImage, scale: UIScreen.main.scale, orientation: .up)

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

        let mirroredImage = mirroredIfNeeded(processedImage)

        guard let cgImage = ciContext.createCGImage(mirroredImage, from: mirroredImage.extent) else {
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
    func updateZoomLimits(for device: AVCaptureDevice) {
        let minZoom = max(0.5, device.minAvailableVideoZoomFactor)
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 6.0)
        let clamped = max(minZoom, min(currentZoomFactor, maxZoom))
        DispatchQueue.main.async {
            self.minZoomFactor = minZoom
            self.maxZoomFactor = maxZoom
            self.currentZoomFactor = clamped
        }
        setZoomFactor(clamped)
    }

    func updateConnectionsOrientation() {
        let orientation = videoOrientation
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
            connection.isVideoMirrored = false
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
            connection.isVideoMirrored = false
        }
    }

    func updatePreviewAspectRatio(for device: AVCaptureDevice) {
        let formatDescription = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let aspect = videoOrientation == .portrait || videoOrientation == .portraitUpsideDown
            ? CGFloat(dimensions.height) / CGFloat(dimensions.width)
            : CGFloat(dimensions.width) / CGFloat(dimensions.height)
        DispatchQueue.main.async {
            self.previewAspectRatio = aspect
        }
    }

    enum LUTParserError: LocalizedError {
        case invalidFormat
        case missingSize
        case invalidDataCount
        case invalidDomain

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Invalid LUT format."
            case .missingSize:
                return "LUT size is missing."
            case .invalidDataCount:
                return "LUT data count does not match the expected size."
            case .invalidDomain:
                return "LUT domain is invalid."
            }
        }
    }

    func parseCubeLUT(from url: URL) throws -> LUTFilter {
        let content = try String(contentsOf: url)
        let lines = content.components(separatedBy: .newlines)

        var size: Int?
        var values: [Float] = []

        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let upperLine = line.uppercased()
            if upperLine.hasPrefix("LUT_3D_SIZE") {
                let components = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
                if let dimension = components.last {
                    size = dimension
                }
                continue
            }

            if upperLine.hasPrefix("DOMAIN_MIN") {
                let components = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
                guard components.count == 3 else { throw LUTParserError.invalidFormat }
                domainMin = SIMD3<Float>(components[0], components[1], components[2])
                continue
            }

            if upperLine.hasPrefix("DOMAIN_MAX") {
                let components = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
                guard components.count == 3 else { throw LUTParserError.invalidFormat }
                domainMax = SIMD3<Float>(components[0], components[1], components[2])
                continue
            }

            let components = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard components.count == 3 else { continue }

            guard let r = Float(components[0]),
                  let g = Float(components[1]),
                  let b = Float(components[2]) else {
                throw LUTParserError.invalidFormat
            }

            values.append(contentsOf: [r, g, b])
        }

        guard let cubeSize = size else { throw LUTParserError.missingSize }

        let expectedValueCount = cubeSize * cubeSize * cubeSize * 3
        guard values.count == expectedValueCount else { throw LUTParserError.invalidDataCount }

        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y, domainMax.z > domainMin.z else {
            throw LUTParserError.invalidDomain
        }

        if let maxValue = values.max(), maxValue > 1.0 {
            let normalizationFactor: Float = maxValue <= 255 ? 255.0 : maxValue
            values = values.map { $0 / normalizationFactor }
        }

        var cubeData = Data(capacity: cubeSize * cubeSize * cubeSize * 4 * MemoryLayout<Float>.size)

        for i in stride(from: 0, to: values.count, by: 3) {
            var r = values[i]
            var g = values[i + 1]
            var b = values[i + 2]
            var a: Float = 1.0

            // 🔥 关键：把 R / B 互换写入，让 LUT 体按 BGR 排布
            withUnsafeBytes(of: &b) { cubeData.append(contentsOf: $0) } // B
            withUnsafeBytes(of: &g) { cubeData.append(contentsOf: $0) } // G
            withUnsafeBytes(of: &r) { cubeData.append(contentsOf: $0) } // R
            withUnsafeBytes(of: &a) { cubeData.append(contentsOf: $0) } // A
        }


        let name = url.deletingPathExtension().lastPathComponent
        return LUTFilter(name: name, cubeSize: cubeSize, cubeData: cubeData, domainMin: domainMin, domainMax: domainMax)
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
        var workingImage = ciImage

        if lut.domainMin != SIMD3<Float>(repeating: 0) || lut.domainMax != SIMD3<Float>(repeating: 1) {
            guard let scaled = applyDomainMapping(to: workingImage, min: lut.domainMin, max: lut.domainMax) else {
                print("Failed to scale image into LUT domain")
                return nil
            }
            workingImage = scaled
        }

        guard let filter = CIFilter(name: "CIColorCube") else {
            print("Failed to create CIColorCube filter")
            return nil
        }
        filter.setValue(workingImage, forKey: kCIInputImageKey)
        filter.setValue(lut.cubeSize, forKey: "inputCubeDimension")
        filter.setValue(lut.cubeData, forKey: "inputCubeData")
        guard let output = filter.outputImage else {
            print("CIColorCube failed to produce output image")
            return nil
        }
        return output
    }

    func mirroredIfNeeded(_ image: CIImage) -> CIImage {
        guard isFrontCamera else { return image }
        let transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0)
        return image.transformed(by: transform)
    }

    func applyDomainMapping(to image: CIImage, min: SIMD3<Float>, max: SIMD3<Float>) -> CIImage? {
        let range = max - min
        guard range.x > 0, range.y > 0, range.z > 0 else { return nil }

        guard let matrixFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        matrixFilter.setValue(image, forKey: kCIInputImageKey)
        matrixFilter.setValue(CIVector(x: CGFloat(1.0 / range.x), y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrixFilter.setValue(CIVector(x: 0, y: CGFloat(1.0 / range.y), z: 0, w: 0), forKey: "inputGVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: CGFloat(1.0 / range.z), w: 0), forKey: "inputBVector")
        matrixFilter.setValue(CIVector(x: CGFloat(-min.x / range.x), y: CGFloat(-min.y / range.y), z: CGFloat(-min.z / range.z), w: 0), forKey: "inputBiasVector")

        guard let scaledImage = matrixFilter.outputImage else { return nil }

        guard let clampFilter = CIFilter(name: "CIColorClamp") else { return scaledImage }
        clampFilter.setValue(scaledImage, forKey: kCIInputImageKey)
        clampFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        clampFilter.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")

        return clampFilter.outputImage ?? scaledImage
    }
}

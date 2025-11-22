//
//  ContentView.swift
//  Camera
//
//  Created by 黄斌 on 2025/11/22.
//

import SwiftUI
import Combine
import UIKit
import AVFoundation

final class CameraModel: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published var isSessionRunning = false
    @Published var capturedImage: UIImage?

    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()

    override init() {
        super.init()
        checkPermissions()
    }

    func checkPermissions() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch authorizationStatus {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = granted ? .authorized : .denied
                }
                if granted {
                    self?.configureSession()
                }
            }
        default:
            break
        }
    }

    func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                return
            }

            if self.session.inputs.isEmpty {
                self.session.addInput(input)
            }

            guard self.session.canAddOutput(self.photoOutput) else {
                self.session.commitConfiguration()
                return
            }
            if !self.session.outputs.contains(where: { $0 === self.photoOutput }) {
                self.session.addOutput(self.photoOutput)
            }

            self.photoOutput.isHighResolutionCaptureEnabled = true

            self.session.commitConfiguration()

            self.session.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func capturePhoto() {
        guard authorizationStatus == .authorized else { return }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else { return }

        DispatchQueue.main.async {
            self.capturedImage = image
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct ContentView: View {
    @StateObject private var cameraModel = CameraModel()

    var body: some View {
        ZStack {
            switch cameraModel.authorizationStatus {
            case .authorized:
                cameraInterface
            case .denied, .restricted:
                permissionView
            case .notDetermined:
                ProgressView("Requesting camera access…")
            @unknown default:
                Text("Unsupported permission state")
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var cameraInterface: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
            CameraPreview(session: cameraModel.session)
                .overlay(alignment: .bottom) {
                    captureControls
                        .padding(.bottom, 32)
                }
                .ignoresSafeArea()
        }
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Camera access needed")
                .font(.title3)
                .bold()
            Text("Enable camera permissions in Settings to take photos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private var captureControls: some View {
        HStack(spacing: 24) {
            if let image = cameraModel.capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipped()
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            }

            Button(action: cameraModel.capturePhoto) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 82, height: 82)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }
}

#Preview {
    ContentView()
}
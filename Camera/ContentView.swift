import SwiftUI
import AVFoundation
import Photos

struct ContentView: View {
    @StateObject private var cameraViewModel = CameraViewModel()
    @State private var showDocumentPicker = false

    var body: some View {
        Group {
            switch cameraViewModel.authorizationStatus {
            case .authorized:
                authorizedView
            case .notDetermined:
                permissionPrompt
            case .denied, .restricted:
                deniedView
            @unknown default:
                deniedView
            }
        }
        .onAppear {
            cameraViewModel.checkPermissions()
        }
        .onDisappear {
            cameraViewModel.stopSession()
        }
        .sheet(isPresented: $showDocumentPicker) {
            CubeDocumentPicker { url in
                cameraViewModel.importLUT(from: url)
            }
        }
    }

    private var authorizedView: some View {
        ZStack {
            FilteredCameraPreview(viewModel: cameraViewModel)
                .ignoresSafeArea()

            VStack {
                Spacer()
                HStack(alignment: .center) {
                    if let image = cameraViewModel.lastCapturedImage {
                        Button(action: {
                            cameraViewModel.openLastSavedPhoto()
                        }) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.8), lineWidth: 2))
                                .padding(.leading, 24)
                        }
                    } else {
                        Spacer().frame(width: 104)
                    }

                    Spacer()

                    Button(action: {
                        cameraViewModel.capturePhoto()
                    }) {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 6)
                            .background(Circle().fill(Color.white.opacity(0.8)))
                            .frame(width: 86, height: 86)
                            .shadow(radius: 4)
                    }
                    .padding(.bottom, 10)

                    Spacer()

                    Spacer().frame(width: 104)
                }
                .padding(.bottom, 32)
                .background(
                    LinearGradient(gradient: Gradient(colors: [Color.black.opacity(0.4), Color.black.opacity(0.1), .clear]), startPoint: .bottom, endPoint: .top)
                        .ignoresSafeArea()
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 8) {
                if cameraViewModel.photoAuthorizationStatus == .denied || cameraViewModel.photoAuthorizationStatus == .restricted {
                    Text("Photo Library access is required to save photos.")
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)

                    Button(action: openSettings) {
                        Text("Open Settings")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.9))
                            .foregroundColor(.black)
                            .cornerRadius(12)
                    }
                }

                if let message = cameraViewModel.savingMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                }
            }
            .padding([.leading, .bottom], 20)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button(action: {
                        showDocumentPicker = true
                    }) {
                        Text("Import LUT")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.9))
                            .foregroundColor(.black)
                            .cornerRadius(10)
                    }

                    Menu {
                        Button("None") {
                            cameraViewModel.selectedLUT = nil
                        }
                        ForEach(cameraViewModel.availableLUTs) { lut in
                            Button(lut.name) {
                                cameraViewModel.selectedLUT = lut
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("LUT: \(cameraViewModel.selectedLUT?.name ?? "None")")
                                .font(.footnote.weight(.semibold))
                            Image(systemName: "chevron.down")
                                .font(.footnote.bold())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }

                if let message = cameraViewModel.lutStatusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                }
            }
            .padding([.top, .leading], 20)
        }
        .onAppear {
            cameraViewModel.startSession()
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Text("Camera Access Needed")
                .font(.title2)
                .bold()
            Text("Please allow camera access to take photos.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button(action: {
                cameraViewModel.checkPermissions()
            }) {
                Text("Grant Camera Access")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .padding()
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Text("Camera Access Denied")
                .font(.title2)
                .bold()
            Text("Please enable camera access in Settings to use the camera.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button(action: openSettings) {
                Text("Open Settings")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .padding()
    }

    private func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(settingsURL) else { return }
        UIApplication.shared.open(settingsURL)
    }
}

struct FilteredCameraPreview: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let image = viewModel.currentPreviewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

#Preview {
    ContentView()
}

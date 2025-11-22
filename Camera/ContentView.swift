import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cameraViewModel = CameraViewModel()

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
    }

    private var authorizedView: some View {
        ZStack {
            CameraPreviewView(session: cameraViewModel.session)
                .ignoresSafeArea()

            VStack {
                Spacer()
                HStack(alignment: .center) {
                    if let image = cameraViewModel.lastCapturedImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.8), lineWidth: 2))
                            .padding(.leading, 24)
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

#Preview {
    ContentView()
}

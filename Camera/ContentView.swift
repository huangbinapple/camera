import SwiftUI
import AVFoundation
import Photos

struct ContentView: View {
    @StateObject private var cameraViewModel = CameraViewModel()
    @State private var showDocumentPicker = false
    @State private var showOptionsSheet = false
    @State private var pinchBaseZoom: CGFloat = 1.0

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
        .sheet(isPresented: $showOptionsSheet) {
            NavigationView {
                List {
                    Section("LUTs") {
                        Button("Import LUT") {
                            showOptionsSheet = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showDocumentPicker = true
                            }
                        }
                        Picker("Selected LUT", selection: $cameraViewModel.selectedLUT) {
                            Text("None").tag(LUTFilter?.none)
                            ForEach(cameraViewModel.availableLUTs) { lut in
                                Text(lut.name).tag(LUTFilter?.some(lut))
                            }
                        }
                    }
                    Section("Info") {
                        Text("Flash: \(cameraViewModel.currentFlashMode.label)")
                        Text("Zoom: \(String(format: "%.1fx", cameraViewModel.currentZoomFactor))")
                    }
                }
                .navigationTitle("Options")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showOptionsSheet = false }
                    }
                }
            }
        }
    }

    private var authorizedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                previewArea
                controlArea
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
        .onAppear {
            pinchBaseZoom = cameraViewModel.currentZoomFactor
            cameraViewModel.startSession()
        }
        .onChange(of: cameraViewModel.currentZoomFactor) { newValue in
            pinchBaseZoom = newValue
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

    private var previewArea: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                FilteredCameraPreview(viewModel: cameraViewModel)
                    .overlay(GridOverlayView().stroke(style: StrokeStyle(lineWidth: 0.6)).foregroundColor(Color.white.opacity(0.7)))

                if let focusPoint = cameraViewModel.focusPoint, cameraViewModel.isShowingFocusIndicator {
                    FocusIndicatorView()
                        .position(focusPoint)
                }

                VStack {
                    topBar
                        .padding([.top, .horizontal], 20)
                    Spacer()
                    zoomControl
                        .padding(.bottom, 16)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        cameraViewModel.focus(at: value.location, frameSize: size)
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        cameraViewModel.setZoom(to: pinchBaseZoom * value)
                    }
                    .onEnded { _ in
                        pinchBaseZoom = cameraViewModel.currentZoomFactor
                    }
            )
        }
        .aspectRatio(cameraViewModel.previewAspectRatio, contentMode: .fit)
        .background(Color.black)
    }

    private var controlArea: some View {
        VStack(spacing: 12) {
            HStack {
                if let image = cameraViewModel.lastCapturedImage {
                    Button(action: {
                        cameraViewModel.openLastSavedPhoto()
                    }) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.8), lineWidth: 2))
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 64, height: 64)
                }

                Spacer()

                Button(action: {
                    if cameraViewModel.currentMode == .photo {
                        cameraViewModel.capturePhoto()
                    }
                }) {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 5)
                        .background(Circle().fill(Color.white.opacity(cameraViewModel.currentMode == .photo ? 1.0 : 0.3)))
                        .frame(width: 86, height: 86)
                        .shadow(radius: 4)
                }
                .disabled(cameraViewModel.currentMode != .photo)

                Spacer()

                Button(action: {
                    cameraViewModel.switchCamera()
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }
            .padding(.horizontal, 24)

            ModeSelectorView(selectedMode: $cameraViewModel.currentMode)
                .padding(.bottom, 8)
        }
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(
            LinearGradient(gradient: Gradient(colors: [Color.black.opacity(0.7), Color.black.opacity(0.9)]), startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var topBar: some View {
        HStack {
            Text("HEIF")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.2))
                .clipShape(Capsule())

            Spacer()

            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)

            Spacer()

            Button(action: {
                cameraViewModel.cycleFlashMode()
            }) {
                Text(cameraViewModel.currentFlashMode.icon)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
            }

            Button(action: {
                showOptionsSheet = true
            }) {
                Image(systemName: "ellipsis")
                    .font(.headline.bold())
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
        }
        .foregroundColor(.white)
    }

    private var zoomControl: some View {
        HStack(spacing: 12) {
            ForEach(zoomPresets, id: \.self) { factor in
                let isSelected = abs(cameraViewModel.currentZoomFactor - factor) < 0.15
                Button(action: {
                    pinchBaseZoom = factor
                    cameraViewModel.setZoomPreset(factor)
                }) {
                    Text(String(format: "%.1fx", factor))
                        .font(.callout.bold())
                        .foregroundColor(isSelected ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(isSelected ? Color.white : Color.black.opacity(0.4))
                        )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.35))
        .clipShape(Capsule())
    }

    private var zoomPresets: [CGFloat] {
        [0.5, 1.0, 2.0, 3.0]
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
                        .aspectRatio(viewModel.previewAspectRatio, contentMode: .fit)
                        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        .background(Color.black)
                } else {
                    Color.black
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct GridOverlayView: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let thirdsX = [rect.width / 3, rect.width * 2 / 3]
        let thirdsY = [rect.height / 3, rect.height * 2 / 3]

        for x in thirdsX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        for y in thirdsY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        return path
    }
}

struct FocusIndicatorView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.yellow, lineWidth: 2)
            .frame(width: 90, height: 90)
            .shadow(color: .yellow.opacity(0.8), radius: 6)
            .transition(.opacity.combined(with: .scale))
    }
}

struct ModeSelectorView: View {
    @Binding var selectedMode: CameraViewModel.CameraMode

    var body: some View {
        HStack(spacing: 20) {
            ForEach(CameraViewModel.CameraMode.allCases, id: \.self) { mode in
                let isSelected = mode == selectedMode
                Button(action: { selectedMode = mode }) {
                    Text(mode.rawValue)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isSelected ? Color.white.opacity(0.2) : Color.clear)
                        )
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

#Preview {
    ContentView()
}

import SwiftUI
import AVFoundation
import Photos

struct ContentView: View {
    @StateObject private var cameraViewModel = CameraViewModel()
    @State private var showDocumentPicker = false
    @State private var showOptionsSheet = false
    @State private var focusLocation: CGPoint?
    @State private var focusVisible = false
    @State private var isPinching = false
    @State private var pinchStartZoom: CGFloat = 1.0

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
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                previewArea

                controlArea
            }
        }
        .sheet(isPresented: $showOptionsSheet) {
            OptionsSheetView(
                viewModel: cameraViewModel,
                showDocumentPicker: $showDocumentPicker
            )
            .presentationDetents([.medium, .large])
            .presentationBackground(.black)
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

                if let lutMessage = cameraViewModel.lutStatusMessage {
                    Text(lutMessage)
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
        .overlay(alignment: .top) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 18)
        }
        .onAppear {
            cameraViewModel.startSession()
        }
    }

    private var previewArea: some View {
        GeometryReader { geometry in
            let aspect = cameraViewModel.previewAspectRatio
            let containerSize = geometry.size
            let fitWidth: CGFloat
            let fitHeight: CGFloat

            if containerSize.width / containerSize.height > aspect {
                fitHeight = containerSize.height
                fitWidth = fitHeight * aspect
            } else {
                fitWidth = containerSize.width
                fitHeight = fitWidth / aspect
            }

            let previewFrame = CGRect(
                origin: CGPoint(x: (containerSize.width - fitWidth) / 2, y: (containerSize.height - fitHeight) / 2),
                size: CGSize(width: fitWidth, height: fitHeight)
            )

            let pinchGesture = MagnificationGesture()
                .onChanged { value in
                    if !isPinching {
                        pinchStartZoom = cameraViewModel.currentZoomFactor
                        isPinching = true
                    }
                    let newZoom = pinchStartZoom * value
                    cameraViewModel.setZoomFactor(newZoom)
                }
                .onEnded { _ in
                    isPinching = false
                    pinchStartZoom = cameraViewModel.currentZoomFactor
                }

            let tapGesture = DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let location = value.location
                    guard previewFrame.contains(location) else { return }
                    let normalizedX = (location.x - previewFrame.minX) / previewFrame.width
                    let normalizedY = (location.y - previewFrame.minY) / previewFrame.height
                    let normalized = CGPoint(x: normalizedX, y: normalizedY)
                    cameraViewModel.focus(at: normalized)
                    showFocusIndicator(at: location)
                }

            ZStack {
                FilteredCameraPreview(viewModel: cameraViewModel)
                    .frame(width: previewFrame.width, height: previewFrame.height)
                    .position(x: containerSize.width / 2, y: containerSize.height / 2)
                    .overlay(
                        GridOverlayView()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
                            .frame(width: previewFrame.width, height: previewFrame.height)
                    )
                    .clipped()
                    .gesture(pinchGesture)
                    .simultaneousGesture(tapGesture)

                if let point = focusLocation {
                    FocusIndicatorView()
                        .frame(width: 90, height: 90)
                        .position(point)
                        .opacity(focusVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: focusVisible)
                }

                VStack {
                    Spacer()
                    ZoomControlView(viewModel: cameraViewModel) { factor in
                        cameraViewModel.setZoomFactor(factor)
                        pinchStartZoom = factor
                    }
                    .padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 64, height: 64)
                }

                Spacer()

                Button(action: {
                    guard cameraViewModel.currentMode == .photo else { return }
                    cameraViewModel.capturePhoto()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 94, height: 94)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 78, height: 78)
                    }
                }
                .disabled(cameraViewModel.currentMode != .photo)

                Spacer()

                Button(action: {
                    cameraViewModel.switchCamera()
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 24)

            ModeSelectorView(currentMode: cameraViewModel.currentMode) { mode in
                cameraViewModel.setMode(mode)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(
            LinearGradient(gradient: Gradient(colors: [Color.black.opacity(0.8), Color.black.opacity(0.6), Color.black.opacity(0.3)]), startPoint: .bottom, endPoint: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var topBar: some View {
        HStack {
            Text("HEIF")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())

            Spacer()

            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)

            Spacer()

            HStack(spacing: 14) {
                Button(action: {
                    cameraViewModel.cycleFlashMode()
                }) {
                    Text("⚡︎ \(cameraViewModel.flashMode.displaySymbol)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }

                Button(action: {
                    showOptionsSheet = true
                }) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
            }
        }
        .foregroundColor(.white)
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

    private func showFocusIndicator(at point: CGPoint) {
        focusLocation = point
        focusVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.2)) {
                focusVisible = false
            }
        }
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
        let thirdWidth = rect.width / 3
        let thirdHeight = rect.height / 3

        for index in 1..<3 {
            let x = thirdWidth * CGFloat(index)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = thirdHeight * CGFloat(index)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        return path
    }
}

struct FocusIndicatorView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(Color.yellow, lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.1)))
            .shadow(color: Color.yellow.opacity(0.7), radius: 6)
    }
}

struct ZoomControlView: View {
    @ObservedObject var viewModel: CameraViewModel
    var onSelect: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(viewModel.zoomPresets, id: \.self) { factor in
                let isSelected = abs(factor - viewModel.currentZoomFactor) < 0.05
                Button(action: {
                    onSelect(factor)
                }) {
                    Text(String(format: "%.1fx", factor))
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isSelected ? Color.white : Color.white.opacity(0.12))
                        .foregroundColor(isSelected ? .black : .white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.35))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
        )
        .foregroundColor(.white)
    }
}

struct ModeSelectorView: View {
    var currentMode: CameraMode
    var onSelect: (CameraMode) -> Void

    var body: some View {
        HStack(spacing: 24) {
            ForEach(CameraMode.allCases, id: \.self) { mode in
                let isSelected = mode == currentMode
                Button(action: {
                    onSelect(mode)
                }) {
                    Text(mode.displayName)
                        .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                        .foregroundColor(isSelected ? .white : Color.white.opacity(0.7))
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

struct OptionsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var showDocumentPicker: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("LUTs")) {
                    Button("Import LUT") {
                        showDocumentPicker = true
                    }
                    Button("None") {
                        viewModel.selectedLUT = nil
                    }
                    ForEach(viewModel.availableLUTs) { lut in
                        Button(lut.name) {
                            viewModel.selectedLUT = lut
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Options")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

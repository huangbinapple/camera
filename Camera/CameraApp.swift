//
//  CameraApp.swift
//  Camera
//
//  Created by 黄斌 on 2025/11/22.
//

import SwiftUI

final class PortraitHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override var shouldAutorotate: Bool {
        false
    }
}

private struct PortraitRootView<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> PortraitHostingController<Content> {
        PortraitHostingController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: PortraitHostingController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}

@main
struct CameraApp: App {
    var body: some Scene {
        WindowGroup {
            PortraitRootView(content: ContentView())
        }
    }
}

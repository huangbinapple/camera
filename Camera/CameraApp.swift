//
//  CameraApp.swift
//  Camera
//
//  Created by 黄斌 on 2025/11/22.
//

import SwiftUI
import UIKit

final class PortraitHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var shouldAutorotate: Bool { false }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }
}

@main
struct CameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            PortraitRootView {
                ContentView()
            }
        }
    }
}

struct PortraitRootView<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> PortraitHostingController<Content> {
        PortraitHostingController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: PortraitHostingController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}

//
//  CameraApp.swift
//  Camera
//
//  Created by 黄斌 on 2025/11/22.
//

import SwiftUI
import UIKit

class PortraitHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .portrait
    }

    override var shouldAutorotate: Bool {
        false
    }
}

class PortraitSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PortraitHostingController(rootView: ContentView())
        self.window = window
        window.makeKeyAndVisible()
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PortraitSceneDelegate.self
        return configuration
    }
}

@main
struct CameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
}

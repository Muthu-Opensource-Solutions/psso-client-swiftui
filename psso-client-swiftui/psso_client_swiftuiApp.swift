//
//  psso_client_swiftuiApp.swift
//  psso-client-swiftui
//
//  Created by test on 02/09/26.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.muthuopensource.psso-client-swiftui", category: "App")

@main
struct psso_client_swiftuiApp: App {
    init() {
        logger.info("Host application launched: psso-client-swiftui")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

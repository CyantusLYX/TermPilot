//
//  TermPilotApp.swift
//  TermPilot
//
//  Created by Lin Yu Xiang on 2026/6/11.
//

import SwiftUI
import SwiftData
import FirebaseCore
import GoogleSignIn
import TipKit

@main
struct TermPilotApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VaultProfile.self,
            HostProfile.self,
            KeychainItemProfile.self,
            SnippetProfile.self,
            AppSettings.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
        try? Tips.configure([
            .datastoreLocation(.applicationDefault)
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusApp/DictusApp.swift (URL and scenePhase handling). MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
import SwiftUI

@main
struct PrivateWhisperApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var session: SessionController

    init() {
        session = SessionController.shared            // initialise at launch: Darwin receivers + launch hygiene
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { SessionController.shared.handleURL($0) }
                .fullScreenCover(isPresented: $session.showSwipeBack) { SwipeBackView() }
                .sheet(isPresented: $session.showPrepare) { NavigationStack { OnboardingView(prepareOnly: true) } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { SessionController.shared.didEnterBackground() }
        }
    }
}

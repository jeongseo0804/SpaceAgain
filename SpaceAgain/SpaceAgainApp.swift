//
//  SpaceAgainApp.swift
//  Bells-Test-V2
//
//  Created by Interactive 3D Design on 16/8/25.
//

import SwiftUI

@main
struct SpaceAgainApp: App {
    @StateObject private var assessment = AssessmentSession()
    @StateObject private var rehabilitation = RehabilitationSession()
    @StateObject private var patientProfiles = PatientProfileStore()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: AssessmentSession.mainWindowID) {
            ContentView()
                .environmentObject(assessment)
                .environmentObject(rehabilitation)
                .environmentObject(patientProfiles)
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: AssessmentSession.immersiveSpaceID) {
            ImmersiveAssessmentView()
                .environmentObject(assessment)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)

        ImmersiveSpace(id: RehabilitationSession.immersiveSpaceID) {
            ImmersiveRehabilitationView()
                .environmentObject(rehabilitation)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

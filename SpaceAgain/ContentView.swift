import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var assessment: AssessmentSession
    @EnvironmentObject private var rehabilitation: RehabilitationSession
    @EnvironmentObject private var patientProfiles: PatientProfileStore
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var launchError: String?
    @State private var activeRehabilitationProfile: SpatialRehabilitationProfile?

    var body: some View {
        Group {
            if patientProfiles.selectedProfile == nil {
                PatientProfileSelectionView()
                    .frame(width: 760, height: 680)
            } else if let summary = rehabilitation.summary {
                RehabilitationSummaryView(
                    summary: summary,
                    profile: activeRehabilitationProfile ?? assessment.rehabilitationProfile,
                    continueTraining: { pathway in
                        Task {
                            await beginRehabilitation(
                                pathway,
                                using: activeRehabilitationProfile ?? assessment.rehabilitationProfile
                            )
                        }
                    },
                    reassess: {
                        Task { await restartAssessmentFlow() }
                    },
                    returnToMain: {
                        returnToMainProfileChooser(summary: summary)
                    }
                )
                .frame(width: 820, height: 720)
                .onAppear { patientProfiles.recordRehabilitation(summary) }
            } else if let result = assessment.result {
                ResultsView(
                    result: result,
                    profile: patientProfiles.selectedProfile?.rehabilitationProfile,
                    restart: {
                        activeRehabilitationProfile = nil
                        assessment.reset()
                    },
                    startRehabilitation: { pathway in
                        Task {
                            await beginRehabilitation(
                                pathway,
                                using: patientProfiles.selectedProfile?.rehabilitationProfile
                            )
                        }
                    },
                    startSimulatorDemo: { side, pathway in
                        Task { await beginSimulatorDemo(side: side, pathway: pathway) }
                    }
                )
                .frame(width: 820, height: 720)
                .onAppear { patientProfiles.recordAssessment(result) }
            } else if let patient = patientProfiles.selectedProfile,
                      patient.rehabilitationProfile != nil {
                PatientProfileDashboardView(
                    patient: patient,
                    startRehabilitation: { pathway in
                        Task {
                            await beginRehabilitation(
                                pathway,
                                using: patientProfiles.selectedProfile?.rehabilitationProfile
                            )
                        }
                    },
                    startReassessment: {
                        Task { await beginAssessment() }
                    },
                    switchPatient: switchPatient
                )
                .frame(width: 820, height: 720)
            } else {
                introduction
                    .frame(width: 720, height: 620)
            }
        }
        .alert(
            "Unable to Open Immersive Space",
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "Please try again.")
        }
    }

    private func returnToMainProfileChooser(summary: RehabilitationSummary) {
        patientProfiles.recordRehabilitation(summary)
        activeRehabilitationProfile = nil
        rehabilitation.reset()
        assessment.reset()
        patientProfiles.select(nil)
    }

    private func switchPatient() {
        activeRehabilitationProfile = nil
        rehabilitation.reset()
        assessment.reset()
        patientProfiles.select(nil)
    }

    @MainActor
    private func restartAssessmentFlow() async {
        // Reset the assessment first while the summary is still visible. When
        // rehabilitation is reset, SwiftUI then moves directly to the launch
        // state instead of briefly rendering the previous results screen.
        activeRehabilitationProfile = nil
        assessment.reset()
        rehabilitation.reset()
        await Task.yield()
        await beginAssessment()
    }

    @MainActor
    private func beginRehabilitation(
        _ pathway: RehabilitationPathway,
        using profile: SpatialRehabilitationProfile?
    ) async {
        guard let profile else { return }
        launchError = nil
        activeRehabilitationProfile = profile
        rehabilitation.prepare(profile: profile, pathway: pathway)
        let outcome = await openImmersiveSpace(id: RehabilitationSession.immersiveSpaceID)
        switch outcome {
        case .opened:
            dismissWindow(id: AssessmentSession.mainWindowID)
        case .userCancelled:
            rehabilitation.cancelLaunch()
        case .error:
            rehabilitation.cancelLaunch()
            launchError = "The immersive rehabilitation space could not be opened."
        @unknown default:
            rehabilitation.cancelLaunch()
            launchError = "The immersive rehabilitation space is unavailable."
        }
    }

    @MainActor
    private func beginSimulatorDemo(
        side: AffectedSide,
        pathway: RehabilitationPathway
    ) async {
        guard side == .left || side == .right else { return }
        let sourceProfile = patientProfiles.selectedProfile?.rehabilitationProfile
        let demoProfile = SpatialRehabilitationProfile(
            updatedAt: Date(),
            affectedSide: side,
            orientationNeed: pathway == .orientation ? 1 : 0,
            explorationNeed: pathway == .exploration ? 1 : 0,
            confidence: 0,
            recommendedPathway: pathway,
            difficultSectors: sourceProfile?.difficultSectors ?? [],
            assessmentCount: sourceProfile?.assessmentCount ?? 1,
            hasReliableHeadTracking: false,
            headTrackingSource: .simulatorCamera
        )
        await beginRehabilitation(pathway, using: demoProfile)
    }

    private var introduction: some View {
        VStack(spacing: 28) {
            Image("SpaceAgainLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("SpaceAgain")
            Text("Spatial Cancellation Assessment")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 14) {
                Label("Look around your space and select every bell you find.", systemImage: "eyes")
                Label("Some non-bell objects are included. Select bells only.", systemImage: "hand.tap")
                Label("Turn your head naturally and explore as much as you wish.", systemImage: "viewfinder")
                Label("When you believe you are done, choose “I’m Finished.”", systemImage: "checkmark.circle")
            }
            .font(.title3)
            .frame(maxWidth: 560, alignment: .leading)

            Text("During the assessment, no hints or remaining-target count will be shown.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                Task { await beginAssessment() }
            } label: {
                Label("Begin Assessment", systemImage: "visionpro")
                    .font(.title3.bold())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(assessment.phase != .ready)

            if assessment.phase == .launching {
                ProgressView("Preparing your space…")
            }
            if let launchError {
                Text(launchError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(48)
    }

    @MainActor
    private func beginAssessment() async {
        launchError = nil
        assessment.prepareAssessment()
        let outcome = await openImmersiveSpace(id: AssessmentSession.immersiveSpaceID)
        switch outcome {
        case .opened:
            dismissWindow(id: AssessmentSession.mainWindowID)
        case .userCancelled:
            assessment.cancelLaunch()
        case .error:
            assessment.cancelLaunch()
            launchError = "The immersive assessment could not be opened. Please try again."
        @unknown default:
            assessment.cancelLaunch()
            launchError = "The immersive assessment is unavailable."
        }
    }
}

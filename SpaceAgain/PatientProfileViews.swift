import SwiftUI

struct PatientProfileSelectionView: View {
    @EnvironmentObject private var patientProfiles: PatientProfileStore
    @State private var showingAddUser = false
    @State private var hasPresentedInitialAddUser = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    Image("SpaceAgainLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("SpaceAgain")
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Choose a Profile", systemImage: "person.2")
                            .font(.largeTitle.bold())
                        Text("Choose a saved patient or add a new user.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showingAddUser = true
                    } label: {
                        Label("Add User", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if patientProfiles.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Profiles", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("Add a user, then complete one baseline Bells assessment to create their rehabilitation profile.")
                    } actions: {
                        Button("Add User") { showingAddUser = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .glassBackgroundEffect()
                } else {
                    Text("Saved Profiles").font(.headline)
                    ForEach(patientProfiles.profiles.sorted { $0.updatedAt > $1.updatedAt }) { profile in
                        Button {
                            patientProfiles.select(profile.id)
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.patientCode).font(.headline)
                                    Text(profileStatus(profile))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .glassBackgroundEffect()
                    }
                }

                Label(
                    "Profiles are stored locally on this device. Use a patient code rather than a full name. This prototype is not a clinical record system.",
                    systemImage: "lock.local"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(34)
        }
        .sheet(isPresented: $showingAddUser) {
            AddPatientProfileView()
                .environmentObject(patientProfiles)
        }
        .onAppear {
            guard !hasPresentedInitialAddUser, patientProfiles.profiles.isEmpty else { return }
            hasPresentedInitialAddUser = true
            showingAddUser = true
        }
    }

    private func profileStatus(_ profile: PatientProfile) -> String {
        guard let date = profile.latestAssessment?.completedAt else {
            return "Assessment not completed"
        }
        let sessions = profile.sessionsSinceAssessment
        return "Assessed \(date.formatted(date: .abbreviated, time: .omitted)) · \(sessions) rehab session\(sessions == 1 ? "" : "s") since assessment"
    }
}

private struct AddPatientProfileView: View {
    @EnvironmentObject private var patientProfiles: PatientProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var patientCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("Add User", systemImage: "person.badge.plus")
                    .font(.largeTitle.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }

            Text("Use a patient code or initials. Avoid entering a full name because this prototype is not a clinical record system.")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Patient code or initials", text: $patientCode)
                .textFieldStyle(.roundedBorder)
                .font(.title2)

            Button {
                if patientProfiles.createProfile(patientCode: patientCode) != nil {
                    dismiss()
                }
            } label: {
                Label("Create User", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(patientCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Label("The profile and session history are stored locally on this device.", systemImage: "lock.local")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(34)
        .frame(width: 560, height: 400)
    }
}

struct PatientProfileDashboardView: View {
    let patient: PatientProfile
    let startRehabilitation: (RehabilitationPathway) -> Void
    let startReassessment: () -> Void
    let switchPatient: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(patient.patientCode).font(.largeTitle.bold())
                        Text("Patient training profile")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Switch Profile", action: switchPatient)
                        .buttonStyle(.bordered)
                }

                if let profile = patient.rehabilitationProfile,
                   let assessment = patient.latestAssessment {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(profile.recommendedPathway.displayName, systemImage: "figure.mind.and.body")
                            .font(.title2.bold())
                        Text(profile.recommendedPathway.explanation)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            metric("Observed side", profile.affectedSide.displayName)
                            metric("Last assessment", assessment.completedAt.formatted(date: .abbreviated, time: .omitted))
                            metric("Rehab since test", "\(patient.sessionsSinceAssessment)")
                        }

                        if patient.programReviewSuggested {
                            Label(
                                "A 10-session programme block is complete. Consider clinician review or reassessment before changing the pathway.",
                                systemImage: "calendar.badge.exclamationmark"
                            )
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                        }

                        if profile.canBeginTraining && profile.hasUsableTrackingForCurrentRun {
                            Button {
                                startRehabilitation(profile.recommendedPathway)
                            } label: {
                                Label("Continue Recommended Rehabilitation", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            DisclosureGroup("Choose a different pathway") {
                                HStack {
                                    Button("Orientation") { startRehabilitation(.orientation) }
                                    Button("Exploration") { startRehabilitation(.exploration) }
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, 8)
                            }
                        } else {
                            Label(
                                "The saved assessment does not support automatic side-specific training. Clinician review or reassessment is recommended.",
                                systemImage: "person.crop.circle.badge.exclamationmark"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .padding(20)
                    .glassBackgroundEffect()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("When to reassess").font(.headline)
                        Text("Rehabilitation can be repeated from this saved profile. Reassess when a clinician requests it, after a meaningful change in function, or when reviewing the next programme block.")
                            .foregroundStyle(.secondary)
                        Button("Run Uncued Reassessment", action: startReassessment)
                            .buttonStyle(.bordered)
                    }
                    .padding(20)
                    .glassBackgroundEffect()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A baseline assessment is needed").font(.title2.bold())
                        Text("Complete one uncued Bells assessment to create this patient's side-specific rehabilitation profile.")
                            .foregroundStyle(.secondary)
                        Button("Begin Baseline Assessment", action: startReassessment)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .glassBackgroundEffect()
                }

                Text("The saved profile supports training continuity; it is not a diagnosis and does not replace clinical review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

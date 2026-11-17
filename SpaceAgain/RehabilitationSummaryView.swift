import SwiftUI

struct RehabilitationSummaryView: View {
    let summary: RehabilitationSummary
    let profile: SpatialRehabilitationProfile?
    let continueTraining: (RehabilitationPathway) -> Void
    let reassess: () -> Void
    let returnToMain: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Rehabilitation Session Complete", systemImage: "figure.mind.and.body")
                    .font(.title.bold())

                Text(summary.pathway.displayName)
                    .font(.title2.bold())
                Text("Training focused on the \(summary.affectedSide.displayName.lowercased()) side. Results below describe practice performance and are not a clinical reassessment.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    metric("Targets", "\(summary.targetsFound) / \(summary.targetCount)")
                    metric("Uncued successes", "\(summary.uncuedSuccesses)")
                    metric("Cues provided", "\(summary.cueCount)")
                    metric("Maximum excursion", String(format: "%.0f°", summary.maximumAffectedExcursion))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Head-tracking outcomes").font(.headline)
                    Text("First affected-side orientation: \(formatted(summary.affectedInitiationLatency))")
                    Text("Angular regions visited: \(summary.coveredBins.count)")
                    Text("Session duration: \(formatted(summary.duration))")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassBackgroundEffect()

                Text("Next step")
                    .font(.headline)
                Text(nextStepText)
                    .foregroundStyle(.secondary)

                HStack {
                    if summary.pathway == .orientation, profile?.canBeginTraining == true {
                        Button("Continue to Next Rehab Step") { continueTraining(.exploration) }
                            .buttonStyle(.borderedProminent)
                    } else if profile?.canBeginTraining == true {
                        Button("Repeat Recommended Training") {
                            continueTraining(profile?.recommendedPathway == .orientation ? .orientation : .exploration)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Start Uncued Reassessment", action: reassess)
                        .buttonStyle(.borderedProminent)
                }

                Button(action: returnToMain) {
                    Label("Go Back to Main", systemImage: "person.2")
                }
                .buttonStyle(.bordered)

                Text("Prototype rehabilitation output only. Training progression should be reviewed by an appropriately qualified clinician.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }

    private var nextStepText: String {
        if summary.pathway == .orientation, profile?.recommendedPathway == .blended {
            "Next in your blended rehab course: guided exploration practice. Continue when your clinician confirms you are ready."
        } else if summary.pathway == .orientation {
            "Continue to systematic exploration after the user can reliably initiate affected-side head movement without repeated cues."
        } else {
            "Use an uncued assessment to determine whether improved training performance transfers to independent spatial exploration."
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .glassBackgroundEffect()
    }

    private func formatted(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.1f s", $0) } ?? "Not recorded"
    }

    private func formatted(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }
}

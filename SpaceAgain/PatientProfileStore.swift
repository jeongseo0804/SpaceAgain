import Foundation

struct RehabilitationSessionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let completedAt: Date
    let pathway: RehabilitationPathway
    let affectedSide: AffectedSide
    let targetsFound: Int
    let targetCount: Int
    let uncuedSuccesses: Int
    let cueCount: Int
    let affectedInitiationLatency: TimeInterval?
    let maximumAffectedExcursion: Double
    let coveredRegionCount: Int
    let duration: TimeInterval

    init(summary: RehabilitationSummary) {
        id = summary.id
        completedAt = summary.completedAt
        pathway = summary.pathway
        affectedSide = summary.affectedSide
        targetsFound = summary.targetsFound
        targetCount = summary.targetCount
        uncuedSuccesses = summary.uncuedSuccesses
        cueCount = summary.cueCount
        affectedInitiationLatency = summary.affectedInitiationLatency
        maximumAffectedExcursion = summary.maximumAffectedExcursion
        coveredRegionCount = summary.coveredBins.count
        duration = summary.duration
    }
}

struct PatientProfile: Codable, Identifiable {
    let id: UUID
    var patientCode: String
    let createdAt: Date
    var updatedAt: Date
    var assessments: [AssessmentResult]
    var rehabilitationProfile: SpatialRehabilitationProfile?
    var rehabilitationSessions: [RehabilitationSessionRecord]

    var latestAssessment: AssessmentResult? { assessments.last }
    var sessionsSinceAssessment: Int {
        guard let assessmentDate = latestAssessment?.completedAt else { return 0 }
        return rehabilitationSessions.filter { $0.completedAt > assessmentDate }.count
    }

    /// Ten sessions reflects a published immersive visual-training programme
    /// block. It is a review prompt, not a validated clinical cut-off.
    var programReviewSuggested: Bool { sessionsSinceAssessment >= 10 }
}

@MainActor
final class PatientProfileStore: ObservableObject {
    @Published private(set) var profiles: [PatientProfile] = []
    @Published private(set) var selectedProfileID: UUID?

    private let storageKey = "patient-profiles-v1"

    var selectedProfile: PatientProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([PatientProfile].self, from: data) {
            profiles = decoded
        }

        // Always begin at the profile chooser. Patient data remains saved, but
        // no patient is silently carried over from a previous app session.
        selectedProfileID = nil
        UserDefaults.standard.removeObject(forKey: "selected-patient-profile-v1")
    }

    @discardableResult
    func createProfile(patientCode: String) -> PatientProfile? {
        let trimmed = patientCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let profile = PatientProfile(
            id: UUID(),
            patientCode: trimmed,
            createdAt: now,
            updatedAt: now,
            assessments: [],
            rehabilitationProfile: nil,
            rehabilitationSessions: []
        )
        profiles.append(profile)
        select(profile.id)
        persist()
        return profile
    }

    func select(_ id: UUID?) {
        selectedProfileID = id
    }

    func recordAssessment(_ result: AssessmentResult) {
        guard let index = selectedIndex else { return }
        if profiles[index].assessments.contains(where: { $0.completedAt == result.completedAt }) {
            return
        }

        let previousResults = profiles[index].assessments
        profiles[index].assessments.append(result)
        profiles[index].assessments = Array(profiles[index].assessments.suffix(20))
        profiles[index].rehabilitationProfile = RehabilitationProfileAnalyzer.makeProfile(
            from: result,
            previousResults: previousResults
        )
        profiles[index].updatedAt = Date()
        persist()
    }

    func recordRehabilitation(_ summary: RehabilitationSummary) {
        guard let index = selectedIndex else { return }
        if profiles[index].rehabilitationSessions.contains(where: { $0.id == summary.id }) {
            return
        }
        profiles[index].rehabilitationSessions.append(RehabilitationSessionRecord(summary: summary))
        profiles[index].rehabilitationSessions = Array(
            profiles[index].rehabilitationSessions.suffix(100)
        )
        profiles[index].updatedAt = Date()
        persist()
    }

    private var selectedIndex: Int? {
        guard let selectedProfileID else { return nil }
        return profiles.firstIndex { $0.id == selectedProfileID }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

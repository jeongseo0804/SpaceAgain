import Foundation

enum AffectedSide: String, Codable, CaseIterable {
    case left, right, none, uncertain

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .none: "No clear side"
        case .uncertain: "Uncertain"
        }
    }

    var direction: Double {
        switch self {
        case .left: -1
        case .right: 1
        case .none, .uncertain: 0
        }
    }
}

enum RehabilitationPathway: String, Codable, CaseIterable, Identifiable {
    case orientation
    case exploration
    case blended
    case notIndicated
    case clinicianReview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .orientation: "Pathway A · Orientation"
        case .exploration: "Pathway B · Exploration"
        case .blended: "Blended A + B"
        case .notIndicated: "No side-specific pathway"
        case .clinicianReview: "Review recommended"
        }
    }

    var explanation: String {
        switch self {
        case .orientation:
            "Prioritizes independently initiating and completing head movement toward the more difficult side."
        case .exploration:
            "Prioritizes systematic search of regions that were reached but not searched effectively."
        case .blended:
            "Begins with orientation practice and progresses to systematic exploration in the same program."
        case .notIndicated:
            "This assessment did not show a clear lateral pattern requiring side-specific training."
        case .clinicianReview:
            "The available measurements are insufficient or inconsistent, so automatic assignment is withheld."
        }
    }
}

struct SpatialRehabilitationProfile: Codable, Equatable {
    let updatedAt: Date
    let affectedSide: AffectedSide
    let orientationNeed: Double
    let explorationNeed: Double
    let confidence: Double
    let recommendedPathway: RehabilitationPathway
    let difficultSectors: [SpatialSector]
    let assessmentCount: Int
    let hasReliableHeadTracking: Bool
    var headTrackingSource: HeadTrackingSource? = nil

    var canBeginTraining: Bool {
        affectedSide == .left || affectedSide == .right
    }

    var hasUsableTrackingForCurrentRun: Bool {
        hasReliableHeadTracking || headTrackingSource == .simulatorCamera
    }

    var isSimulatorDemo: Bool { headTrackingSource == .simulatorCamera }
}

enum RehabilitationProfileAnalyzer {
    /// Prototype decision support only. These values deliberately describe
    /// observed performance and must not be presented as diagnostic cut-offs.
    static func makeProfile(
        from result: AssessmentResult,
        previousResults: [AssessmentResult] = []
    ) -> SpatialRehabilitationProfile {
        let leftAvailable = result.sectorResults.prefix(3).reduce(0) { $0 + $1.targetsAvailable }
        let rightAvailable = result.sectorResults.suffix(3).reduce(0) { $0 + $1.targetsAvailable }
        let leftRate = rate(result.leftOmissions, of: leftAvailable)
        let rightRate = rate(result.rightOmissions, of: rightAvailable)
        let omissionDifference = leftRate - rightRate
        let trackingSource: HeadTrackingSource? = {
            if let source = result.headTrackingSource { return source }
            return result.headTrackingWasReliable == true ? .visionPro : nil
        }()
        let trackingAvailable = trackingSource != nil
        let trackingIsReliable = trackingSource?.isClinicallyReliable == true

        let affectedSide: AffectedSide
        if abs(omissionDifference) >= 0.12 {
            affectedSide = omissionDifference > 0 ? .left : .right
        } else if result.leftOmissions + result.rightOmissions <= 2 {
            affectedSide = .none
        } else {
            affectedSide = .uncertain
        }

        let difficultSectors = result.sectorResults
            .filter { $0.omissions > 0 }
            .sorted {
                if $0.detectionPercentage == $1.detectionPercentage {
                    return $0.omissions > $1.omissions
                }
                return $0.detectionPercentage < $1.detectionPercentage
            }
            .map(\.sector)

        guard affectedSide == .left || affectedSide == .right else {
            return SpatialRehabilitationProfile(
                updatedAt: result.completedAt,
                affectedSide: affectedSide,
                orientationNeed: 0,
                explorationNeed: max(leftRate, rightRate),
                confidence: affectedSide == .none ? 0.75 : 0.35,
                recommendedPathway: affectedSide == .none ? .notIndicated : .clinicianReview,
                difficultSectors: difficultSectors,
                assessmentCount: previousResults.count + 1,
                hasReliableHeadTracking: trackingIsReliable,
                headTrackingSource: trackingSource
            )
        }

        guard trackingAvailable else {
            return SpatialRehabilitationProfile(
                updatedAt: result.completedAt,
                affectedSide: affectedSide,
                orientationNeed: 0,
                explorationNeed: affectedSide == .left ? leftRate : rightRate,
                confidence: 0.30,
                recommendedPathway: .clinicianReview,
                difficultSectors: difficultSectors,
                assessmentCount: previousResults.count + 1,
                hasReliableHeadTracking: false,
                headTrackingSource: nil
            )
        }

        let affectedReach = affectedSide == .left
            ? result.maximumLeftExplorationDegrees
            : result.maximumRightExplorationDegrees
        let oppositeReach = affectedSide == .left
            ? result.maximumRightExplorationDegrees
            : result.maximumLeftExplorationDegrees
        let affectedDwell = affectedSide == .left
            ? result.leftExplorationTime
            : result.rightExplorationTime
        let oppositeDwell = affectedSide == .left
            ? result.rightExplorationTime
            : result.leftExplorationTime
        let affectedOmissionRate = affectedSide == .left ? leftRate : rightRate

        let reachDeficit = clamp((oppositeReach - affectedReach) / 60)
        let dwellDeficit = clamp((oppositeDwell - affectedDwell) / max(1, oppositeDwell))
        let initiationDeficit: Double
        let affectedInitiationTime = affectedSide == .left
            ? result.timeBeforeFirstLeftExploration
            : result.timeBeforeFirstRightExploration
        initiationDeficit = clamp((affectedInitiationTime ?? result.durationSeconds) / 10)

        let orientationNeed = clamp(
            0.45 * reachDeficit + 0.35 * dwellDeficit + 0.20 * initiationDeficit
        )
        let exposure = clamp(affectedReach / 70) * clamp(affectedDwell / max(2, oppositeDwell))
        let explorationNeed = clamp(affectedOmissionRate * (0.65 + 0.35 * exposure))

        let pathway: RehabilitationPathway
        if orientationNeed >= 0.45 && explorationNeed >= 0.45
            && abs(orientationNeed - explorationNeed) < 0.18 {
            pathway = .blended
        } else if orientationNeed > explorationNeed {
            pathway = .orientation
        } else {
            pathway = .exploration
        }

        let priorAgreement = previousResults.suffix(2).filter { prior in
            let priorLeftRate = rate(prior.leftOmissions, of: max(1, prior.leftTargetCount))
            let priorRightRate = rate(prior.rightOmissions, of: max(1, prior.rightTargetCount))
            return affectedSide == .left
                ? priorLeftRate > priorRightRate
                : priorRightRate > priorLeftRate
        }.count
        let confidence = clamp(0.58 + abs(omissionDifference) * 0.7 + Double(priorAgreement) * 0.10)

        return SpatialRehabilitationProfile(
            updatedAt: result.completedAt,
            affectedSide: affectedSide,
            orientationNeed: orientationNeed,
            explorationNeed: explorationNeed,
            confidence: confidence,
            recommendedPathway: pathway,
            difficultSectors: difficultSectors,
            assessmentCount: previousResults.count + 1,
            hasReliableHeadTracking: trackingIsReliable,
            headTrackingSource: trackingSource
        )
    }

    private static func rate(_ count: Int, of total: Int) -> Double {
        total == 0 ? 0 : Double(count) / Double(total)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

struct RehabilitationItem: Identifiable, Hashable {
    let id: UUID
    let angleDegrees: Double
    let elevationDegrees: Double
    let isTarget: Bool
    let variant: Int
}

struct RehabilitationSummary: Identifiable {
    let id = UUID()
    let completedAt: Date
    let pathway: RehabilitationPathway
    let affectedSide: AffectedSide
    let targetsFound: Int
    let targetCount: Int
    let uncuedSuccesses: Int
    let cueCount: Int
    let affectedInitiationLatency: TimeInterval?
    let maximumAffectedExcursion: Double
    let coveredBins: Set<Int>
    let duration: TimeInterval
}

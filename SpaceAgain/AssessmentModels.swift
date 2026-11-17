import Foundation

enum Hemispace: String, Codable, CaseIterable {
    case left, center, right
}

enum SpatialSector: String, Codable, CaseIterable, Identifiable {
    case farLeft, midLeft, nearLeft, center, nearRight, midRight, farRight

    var id: String { rawValue }

    var bounds: ClosedRange<Double> {
        switch self {
        case .farLeft: -90 ... -64.285714
        case .midLeft: -64.285714 ... -38.571429
        case .nearLeft: -38.571429 ... -12.857143
        case .center: -12.857143 ... 12.857143
        case .nearRight: 12.857143 ... 38.571429
        case .midRight: 38.571429 ... 64.285714
        case .farRight: 64.285714 ... 90
        }
    }

    var displayName: String {
        "\(Int(bounds.lowerBound.rounded()))° to \(Int(bounds.upperBound.rounded()))°"
    }

    static func containing(angle: Double) -> SpatialSector {
        switch angle {
        case ..<(-64.285714): .farLeft
        case ..<(-38.571429): .midLeft
        case ..<(-12.857143): .nearLeft
        case ..<12.857143: .center
        case ..<38.571429: .nearRight
        case ..<64.285714: .midRight
        default: .farRight
        }
    }
}

struct AssessmentItem: Identifiable, Hashable, Codable {
    let id: UUID
    let symbol: String
    let isTarget: Bool
    let angleDegrees: Double
    let radiusMeters: Float
    let verticalOffsetMeters: Float

    var hemispace: Hemispace {
        switch sector {
        case .farLeft, .midLeft, .nearLeft: .left
        case .center: .center
        case .nearRight, .midRight, .farRight: .right
        }
    }

    var sector: SpatialSector { .containing(angle: angleDegrees) }
}

struct TargetDetection: Identifiable, Codable {
    let id: UUID
    let itemID: UUID
    let isTarget: Bool
    let itemAngleDegrees: Double
    let headAngleDegrees: Double
    let responseTimeSeconds: TimeInterval
}

enum FirstScanningDirection: String, Codable {
    case left, right, notEstablished

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .notEstablished: "Not established"
        }
    }
}

enum HeadTrackingSource: String, Codable {
    case visionPro
    case simulatorCamera

    var isClinicallyReliable: Bool { self == .visionPro }

    var displayName: String {
        switch self {
        case .visionPro: "Vision Pro head tracking"
        case .simulatorCamera: "Simulator camera rotation (synthetic)"
        }
    }
}

/// Codable so a future visual-scanning training module can consume assessment
/// output without depending on the immersive UI implementation.
struct AssessmentResult: Codable {
    let completedAt: Date
    let durationSeconds: TimeInterval
    let targetCount: Int
    let targetsFound: Int
    let falsePositiveCount: Int
    let leftTargetCount: Int
    let rightTargetCount: Int
    let centerTargetCount: Int
    let leftOmissions: Int
    let rightOmissions: Int
    let centerOmissions: Int
    let meanLeftResponseTime: TimeInterval?
    let meanRightResponseTime: TimeInterval?
    let maximumLeftExplorationDegrees: Double
    let maximumRightExplorationDegrees: Double
    let firstScanningDirection: FirstScanningDirection
    let timeBeforeFirstLeftExploration: TimeInterval?
    let timeBeforeFirstRightExploration: TimeInterval?
    let leftExplorationTime: TimeInterval
    let centerExplorationTime: TimeInterval
    let rightExplorationTime: TimeInterval
    let angularDwellSeconds: [Int: TimeInterval]
    let headTrackingWasReliable: Bool?
    var headTrackingSource: HeadTrackingSource? = nil
    let sectorResults: [SectorResult]
    let detections: [TargetDetection]
}

struct SectorResult: Codable, Identifiable {
    let sector: SpatialSector
    let targetsAvailable: Int
    let targetsCancelled: Int
    let omissions: Int
    let detectionPercentage: Double
    let meanResponseTime: TimeInterval?

    var id: String { sector.id }
}

enum StimulusLayout {
    static let distractors = ["🎸", "🎺", "🔧", "🗝️", "📱", "🍃", "⚡️"]
    static let expectedTargetCount = 35
    static let expectedDistractorCount = 280
    static let horizontalBounds = -90.0 ... 90.0

    private static let targetsPerSector = 5
    private static let distractorsPerSector = 40
    private static let itemsPerSector = targetsPerSector + distractorsPerSector
    private static let azimuthInset = 2.35
    private static let elevationInset = 1.0
    static let minimumAngularSeparationDegrees = 4.4
    // Matches the published ecological VR Bells Test hemisphere: 40 degrees
    // below and 60 degrees above the participant's initial forward direction.
    private static let elevationBounds = -40.0 ... 60.0

    /// Seven sectors reproduce the standardized Bells Test structure: each
    /// sector contains 5 targets and 40 distractors. Together they span a
    /// 180-degree far-space field from -90 to +90 degrees. A fixed seed makes
    /// the pseudo-random layout identical for every administration.
    static func makeItems() -> [AssessmentItem] {
        var generator = SeededGenerator(seed: 0xB311_5A71_A1)
        var items: [AssessmentItem] = []
        var placedPoints: [(azimuth: Double, elevation: Double)] = []

        for (sectorIndex, sector) in SpatialSector.allCases.enumerated() {
            let points = distributedPoints(
                sector: sector,
                avoiding: placedPoints,
                generator: &generator
            )
            placedPoints.append(contentsOf: points)
            let selectedTargetSlots = targetSlots(in: points, generator: &generator)

            for (slot, point) in points.enumerated() {
                let isTarget = selectedTargetSlots.contains(slot)
                let radius: Float = 1.0
                let elevationRadians = point.elevation * .pi / 180
                items.append(AssessmentItem(
                    id: UUID(),
                    symbol: isTarget ? "🔔" : distractors[(sectorIndex * distractorsPerSector + slot) % distractors.count],
                    isTarget: isTarget,
                    angleDegrees: point.azimuth,
                    radiusMeters: radius,
                    verticalOffsetMeters: Float(sin(elevationRadians)) * radius
                ))
            }
        }
        return items.shuffled(using: &generator)
    }

    private static func distributedPoints(
        sector: SpatialSector,
        avoiding occupiedPoints: [(azimuth: Double, elevation: Double)],
        generator: inout SeededGenerator
    ) -> [(azimuth: Double, elevation: Double)] {
        let minimumAzimuth = sector.bounds.lowerBound + azimuthInset
        let maximumAzimuth = sector.bounds.upperBound - azimuthInset
        let minimumElevation = elevationBounds.lowerBound + elevationInset
        let maximumElevation = elevationBounds.upperBound - elevationInset
        let minimumSine = sin(minimumElevation * .pi / 180)
        let maximumSine = sin(maximumElevation * .pi / 180)
        var points: [(azimuth: Double, elevation: Double)] = []
        var attempts = 0

        // Rejection sampling produces a blue-noise-like scatter: irregular to
        // the eye, but with enough spacing to keep neighboring symbols distinct.
        while points.count < itemsPerSector && attempts < 100_000 {
            attempts += 1
            let candidate = (
                azimuth: Double.random(in: minimumAzimuth ... maximumAzimuth, using: &generator),
                elevation: asin(Double.random(in: minimumSine ... maximumSine, using: &generator))
                    * 180 / .pi
            )
            guard points.allSatisfy({
                angularDistance(from: candidate, to: $0) >= minimumAngularSeparationDegrees
            }), occupiedPoints.allSatisfy({
                angularDistance(from: candidate, to: $0) >= minimumAngularSeparationDegrees
            }) else { continue }
            points.append(candidate)
        }

        precondition(points.count == itemsPerSector, "Unable to generate the fixed Bells layout")
        return points
    }

    /// Select one target from each vertical fifth. This keeps target difficulty
    /// comparable between sectors without creating visibly mirrored patterns.
    private static func targetSlots(
        in points: [(azimuth: Double, elevation: Double)],
        generator: inout SeededGenerator
    ) -> Set<Int> {
        let orderedSlots = points.indices.sorted {
            points[$0].elevation < points[$1].elevation
        }
        let slotsPerBand = itemsPerSector / targetsPerSector
        return Set((0 ..< targetsPerSector).map { band in
            let start = band * slotsPerBand
            return orderedSlots[start + Int.random(in: 0 ..< slotsPerBand, using: &generator)]
        })
    }

    private static func angularDistance(
        from first: (azimuth: Double, elevation: Double),
        to second: (azimuth: Double, elevation: Double)
    ) -> Double {
        let firstElevation = first.elevation * .pi / 180
        let secondElevation = second.elevation * .pi / 180
        let azimuthDifference = (first.azimuth - second.azimuth) * .pi / 180
        let cosine = sin(firstElevation) * sin(secondElevation)
            + cos(firstElevation) * cos(secondElevation) * cos(azimuthDifference)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

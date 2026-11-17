import ARKit
import Foundation
import QuartzCore
import simd

@MainActor
final class AssessmentSession: ObservableObject {
    static let immersiveSpaceID = "spatial-cancellation-assessment"
    static let mainWindowID = "assessment-control-window"

    enum Phase: Equatable { case ready, launching, calibrating, assessing, finishing, results }

    enum CalibrationStatus: Equatable {
        case acquiringTracking
        case needsAlignment
        case holdingPosition
        case confirmed
        case trackingUnavailable
    }

    static let calibrationInnerToleranceDegrees = 10.0
    static let calibrationWarningDegrees = 15.0
    static let calibrationHoldDuration: TimeInterval = 5.0
    static let calibrationStillnessDegrees: Float = 3
    static let calibrationStillnessMeters: Float = 0.03
    static let calibrationTrackingGapTolerance: TimeInterval = 0.5
    static let trackingUnavailableMessage =
        "Head tracking unavailable. Please remain still while tracking reconnects."

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var items: [AssessmentItem] = []
    @Published private(set) var selectedItemIDs: Set<UUID> = []
    @Published private(set) var result: AssessmentResult?
    @Published private(set) var rehabilitationProfile: SpatialRehabilitationProfile?
    @Published private(set) var assessmentHistory: [AssessmentResult] = []
    @Published private(set) var initialDeviceTransform: simd_float4x4?
    @Published private(set) var trackingNotice: String?
    @Published private(set) var isHeadTrackingAvailable = false
    @Published private(set) var calibrationStatus: CalibrationStatus = .acquiringTracking
    @Published private(set) var calibrationProgress = 0.0
    @Published private(set) var calibrationAngleDegrees = 0.0
    @Published private(set) var trackingStartupError: String?

    var canBeginAssessment: Bool {
        phase == .calibrating
            && isHeadTrackingAvailable
            && calibrationStatus == .confirmed
    }

    private var arSession = ARKitSession()
    private var trackingRunID = UUID()
    private var trackingTask: Task<Void, Never>?
    private var startTime: TimeInterval = 0
    private var lastSampleTime: TimeInterval?
    private var calibrationHoldStartTime: TimeInterval?
    private var calibrationCandidate: simd_float4x4?
    private var trackingLossStartTime: TimeInterval?
    private var accumulatedTrackingPause: TimeInterval = 0
    private var initialForward = SIMD3<Float>(0, 0, -1)
    private var latestHeadAngle = 0.0
    private var firstDirection: FirstScanningDirection = .notEstablished
    private var maximumLeftDegrees = 0.0
    private var maximumRightDegrees = 0.0
    private var firstLeftTime: TimeInterval?
    private var firstRightTime: TimeInterval?
    private var hemispaceTimes: [Hemispace: TimeInterval] = [:]
    private var angularDwell: [Int: TimeInterval] = [:]
    private var detections: [TargetDetection] = []
    private let historyStorageKey = "spatial-assessment-history-v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: historyStorageKey),
           let decoded = try? JSONDecoder().decode([AssessmentResult].self, from: data) {
            assessmentHistory = Array(decoded.suffix(20))
            if let latest = assessmentHistory.last {
                rehabilitationProfile = RehabilitationProfileAnalyzer.makeProfile(
                    from: latest,
                    previousResults: Array(assessmentHistory.dropLast())
                )
            }
        }
    }

    func prepareAssessment() {
        stopTracking()
        phase = .launching
        items = StimulusLayout.makeItems()
        selectedItemIDs = []
        result = nil
        initialDeviceTransform = nil
        trackingNotice = nil
        isHeadTrackingAvailable = false
        resetCalibration()
        resetAssessmentMetrics()
    }

    func cancelLaunch() { phase = .ready }

    func startCalibration() async {
        guard beginCalibration() else { return }
        let runID = trackingRunID
        let session = ARKitSession()
        arSession = session
        trackingStartupError = nil

        guard WorldTrackingProvider.isSupported else {
            processTrackingSample(nil, at: CACurrentMediaTime())
            trackingStartupError = "This device cannot provide head-position tracking."
            return
        }

        // ARKit providers cannot be run again after the session stops them.
        // Keep a fresh provider local to this run, including its sampling task.
        let worldTracking = WorldTrackingProvider()
        do {
            try await session.run([worldTracking])
            guard runID == trackingRunID, phase == .calibrating else {
                session.stop()
                return
            }
            trackingTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.trackingRunID == runID else { return }
                    let timestamp = CACurrentMediaTime()
                    let anchor = worldTracking.state == .running
                        ? worldTracking.queryDeviceAnchor(atTimestamp: timestamp) : nil
                    self.processTrackingSample(
                        anchor?.isTracked == true ? anchor?.originFromAnchorTransform : nil,
                        at: timestamp
                    )
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        } catch {
            guard runID == trackingRunID else { return }
            processTrackingSample(nil, at: CACurrentMediaTime())
            trackingStartupError = "Head tracking could not start: \(error.localizedDescription)"
        }
    }

    func retryCalibration() async {
        guard phase == .calibrating else { return }
        stopTracking()
        initialDeviceTransform = nil
        isHeadTrackingAvailable = false
        trackingNotice = nil
        resetCalibration()
        phase = .launching
        await startCalibration()
    }

    @discardableResult
    func beginCalibration() -> Bool {
        guard phase == .launching else { return false }
        phase = .calibrating
        calibrationStatus = .acquiringTracking
        return true
    }

    func beginAssessmentAfterCalibration() {
        guard canBeginAssessment else { return }
        resetAssessmentMetrics()
        startTime = CACurrentMediaTime()
        lastSampleTime = startTime
        trackingLossStartTime = nil
        accumulatedTrackingPause = 0
        trackingNotice = nil
        phase = .assessing
    }

    @discardableResult
    func select(itemID: UUID) -> Bool {
        guard phase == .assessing,
              isHeadTrackingAvailable,
              !selectedItemIDs.contains(itemID),
              let item = items.first(where: { $0.id == itemID }) else { return false }
        selectedItemIDs.insert(itemID)
        detections.append(TargetDetection(
            id: UUID(), itemID: itemID, isTarget: item.isTarget,
            itemAngleDegrees: item.angleDegrees,
            headAngleDegrees: latestHeadAngle,
            responseTimeSeconds: activeAssessmentTime(at: CACurrentMediaTime())
        ))
        return true
    }

    @discardableResult
    func finishAssessment() -> Bool {
        guard phase == .assessing, isHeadTrackingAvailable else { return false }
        phase = .finishing
        let duration = activeAssessmentTime(at: CACurrentMediaTime())
        stopTracking()

        let targets = items.filter(\.isTarget)
        let selectedTargets = targets.filter { selectedItemIDs.contains($0.id) }
        let targetDetections = detections.filter(\.isTarget)
        let leftTargets = targets.filter { $0.hemispace == .left }
        let rightTargets = targets.filter { $0.hemispace == .right }
        let centerTargets = targets.filter { $0.hemispace == .center }
#if targetEnvironment(simulator)
        let trackingSource: HeadTrackingSource? = angularDwell.isEmpty ? nil : .simulatorCamera
#else
        let trackingSource: HeadTrackingSource? = angularDwell.isEmpty ? nil : .visionPro
#endif

        let completedResult = AssessmentResult(
            completedAt: Date(), durationSeconds: duration,
            targetCount: targets.count, targetsFound: selectedTargets.count,
            falsePositiveCount: detections.filter { !$0.isTarget }.count,
            leftTargetCount: leftTargets.count, rightTargetCount: rightTargets.count,
            centerTargetCount: centerTargets.count,
            leftOmissions: omissions(in: leftTargets),
            rightOmissions: omissions(in: rightTargets),
            centerOmissions: omissions(in: centerTargets),
            meanLeftResponseTime: meanResponseTime(for: .left, detections: targetDetections),
            meanRightResponseTime: meanResponseTime(for: .right, detections: targetDetections),
            maximumLeftExplorationDegrees: maximumLeftDegrees,
            maximumRightExplorationDegrees: maximumRightDegrees,
            firstScanningDirection: firstDirection,
            timeBeforeFirstLeftExploration: firstLeftTime,
            timeBeforeFirstRightExploration: firstRightTime,
            leftExplorationTime: hemispaceTimes[.left, default: 0],
            centerExplorationTime: hemispaceTimes[.center, default: 0],
            rightExplorationTime: hemispaceTimes[.right, default: 0],
            angularDwellSeconds: angularDwell,
            headTrackingWasReliable: trackingSource?.isClinicallyReliable == true,
            headTrackingSource: trackingSource,
            sectorResults: makeSectorResults(targets: targets, detections: targetDetections),
            detections: detections
        )
        result = completedResult
        record(completedResult)
        phase = .results
        return true
    }

    func reset() {
        stopTracking()
        items = []
        selectedItemIDs = []
        result = nil
        initialDeviceTransform = nil
        trackingNotice = nil
        isHeadTrackingAvailable = false
        resetCalibration()
        resetAssessmentMetrics()
        phase = .ready
    }

    func processTrackingSample(_ transform: simd_float4x4?, at timestamp: TimeInterval) {
        guard phase == .calibrating || phase == .assessing else { return }
        guard let transform else {
            markTrackingUnavailable(at: timestamp)
            return
        }
        restoreTrackingIfNeeded(at: timestamp)
        switch phase {
        case .calibrating:
            processCalibrationTransform(transform, at: timestamp)
        case .assessing:
            processDeviceTransform(transform, at: timestamp)
        default:
            break
        }
    }

    func processCalibrationTransform(_ transform: simd_float4x4, at timestamp: TimeInterval) {
        // Once captured, keep the baseline fixed until a new calibration session.
        guard calibrationStatus != .confirmed else { return }
        if let candidate = calibrationCandidate {
            let rotation = simd_quatf(transform)
            let reference = simd_quatf(candidate)
            let dot = min(Float(1), abs(simd_dot(rotation.vector, reference.vector)))
            let degrees = 2 * acos(dot) * 180 / .pi
            let distance = simd_distance(transform.columns.3, candidate.columns.3)
            if degrees > Self.calibrationStillnessDegrees || distance > Self.calibrationStillnessMeters {
                calibrationCandidate = transform
                calibrationHoldStartTime = timestamp
            }
        } else {
            calibrationCandidate = transform
            calibrationHoldStartTime = timestamp
        }

        let heldDuration = max(0, timestamp - (calibrationHoldStartTime ?? timestamp))
        calibrationProgress = min(1, heldDuration / Self.calibrationHoldDuration)
        calibrationStatus = .holdingPosition
        if heldDuration >= Self.calibrationHoldDuration {
            initialDeviceTransform = transform
            initialForward = horizontalForward(from: transform)
            calibrationAngleDegrees = 0
            calibrationStatus = .confirmed
        }
    }

    private func processDeviceTransform(_ transform: simd_float4x4, at timestamp: TimeInterval) {
        if initialDeviceTransform == nil {
            initialDeviceTransform = transform
            initialForward = horizontalForward(from: transform)
            lastSampleTime = timestamp
            return
        }

        let angle = horizontalAngle(from: transform)
        latestHeadAngle = angle
        let elapsed = activeAssessmentTime(at: timestamp)
        let delta = min(0.1, max(0, timestamp - (lastSampleTime ?? timestamp)))
        lastSampleTime = timestamp

        if angle < -5 {
            hemispaceTimes[.left, default: 0] += delta
            maximumLeftDegrees = max(maximumLeftDegrees, abs(angle))
            if firstLeftTime == nil { firstLeftTime = elapsed }
        } else if angle > 5 {
            hemispaceTimes[.right, default: 0] += delta
            maximumRightDegrees = max(maximumRightDegrees, angle)
            if firstRightTime == nil { firstRightTime = elapsed }
        } else {
            hemispaceTimes[.center, default: 0] += delta
        }
        if firstDirection == .notEstablished {
            if angle <= -8 { firstDirection = .left }
            if angle >= 8 { firstDirection = .right }
        }
        let bin = Int((angle / 15).rounded()) * 15
        angularDwell[min(90, max(-90, bin)), default: 0] += delta
    }

    private func horizontalForward(from transform: simd_float4x4) -> SIMD3<Float> {
        var forward = -SIMD3<Float>(transform.columns.2.x, 0, transform.columns.2.z)
        if simd_length_squared(forward) < 0.0001 { forward = SIMD3<Float>(0, 0, -1) }
        return simd_normalize(forward)
    }

    private func horizontalAngle(from transform: simd_float4x4) -> Double {
        let forward = horizontalForward(from: transform)
        let cross = simd_cross(initialForward, forward)
        let dot = max(-1, min(1, simd_dot(initialForward, forward)))
        return -Double(atan2(cross.y, dot) * 180 / .pi) // Negative is left.
    }

    private func markTrackingUnavailable(at timestamp: TimeInterval) {
        guard phase == .calibrating || phase == .assessing else { return }
        if trackingLossStartTime == nil {
            trackingLossStartTime = timestamp
        }
        isHeadTrackingAvailable = false
        trackingNotice = Self.trackingUnavailableMessage
        lastSampleTime = nil
        if phase == .calibrating, initialDeviceTransform == nil,
           timestamp - (trackingLossStartTime ?? timestamp) >= Self.calibrationTrackingGapTolerance {
            calibrationHoldStartTime = nil
            calibrationCandidate = nil
            calibrationProgress = 0
            calibrationStatus = .trackingUnavailable
        }
    }

    private func restoreTrackingIfNeeded(at timestamp: TimeInterval) {
        let wasUnavailable = !isHeadTrackingAvailable || trackingLossStartTime != nil
        if let lossStart = trackingLossStartTime, phase == .assessing {
            accumulatedTrackingPause += max(0, timestamp - lossStart)
        }
        if let lossStart = trackingLossStartTime, phase == .calibrating,
           initialDeviceTransform == nil {
            let gap = max(0, timestamp - lossStart)
            if gap >= Self.calibrationTrackingGapTolerance {
                calibrationHoldStartTime = nil
                calibrationCandidate = nil
                calibrationProgress = 0
            } else if let holdStart = calibrationHoldStartTime {
                // Missing samples do not count toward the five-second hold.
                calibrationHoldStartTime = holdStart + gap
            }
        }
        trackingLossStartTime = nil
        isHeadTrackingAvailable = true
        trackingNotice = nil
        if wasUnavailable { lastSampleTime = timestamp }
        if phase == .calibrating, calibrationStatus == .trackingUnavailable {
            calibrationStatus = initialDeviceTransform == nil ? .acquiringTracking : .confirmed
        }
    }

    private func activeAssessmentTime(at timestamp: TimeInterval) -> TimeInterval {
        let currentPause = trackingLossStartTime.map { max(0, timestamp - $0) } ?? 0
        return max(0, timestamp - startTime - accumulatedTrackingPause - currentPause)
    }

    private func omissions(in targets: [AssessmentItem]) -> Int {
        targets.filter { !selectedItemIDs.contains($0.id) }.count
    }

    private func meanResponseTime(for hemispace: Hemispace, detections: [TargetDetection]) -> TimeInterval? {
        let values = detections.filter { detection in
            items.first(where: { $0.id == detection.itemID })?.hemispace == hemispace
        }.map(\.responseTimeSeconds)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func makeSectorResults(
        targets: [AssessmentItem],
        detections: [TargetDetection]
    ) -> [SectorResult] {
        SpatialSector.allCases.map { sector in
            let sectorTargets = targets.filter { $0.sector == sector }
            let cancelled = sectorTargets.filter { selectedItemIDs.contains($0.id) }
            let responseTimes = detections
                .filter { SpatialSector.containing(angle: $0.itemAngleDegrees) == sector }
                .map(\.responseTimeSeconds)
            let available = sectorTargets.count
            return SectorResult(
                sector: sector,
                targetsAvailable: available,
                targetsCancelled: cancelled.count,
                omissions: available - cancelled.count,
                detectionPercentage: available == 0 ? 0 : Double(cancelled.count) / Double(available) * 100,
                meanResponseTime: responseTimes.isEmpty
                    ? nil
                    : responseTimes.reduce(0, +) / Double(responseTimes.count)
            )
        }
    }

    private func resetCalibration() {
        trackingStartupError = nil
        calibrationCandidate = nil
        calibrationHoldStartTime = nil
        calibrationProgress = 0
        calibrationAngleDegrees = 0
        calibrationStatus = .acquiringTracking
        trackingLossStartTime = nil
        accumulatedTrackingPause = 0
        initialForward = SIMD3<Float>(0, 0, -1)
    }

    private func resetAssessmentMetrics() {
        startTime = 0
        lastSampleTime = nil
        latestHeadAngle = 0
        firstDirection = .notEstablished
        maximumLeftDegrees = 0
        maximumRightDegrees = 0
        firstLeftTime = nil
        firstRightTime = nil
        hemispaceTimes = [:]
        angularDwell = [:]
        detections = []
    }

    private func record(_ completedResult: AssessmentResult) {
        let previousResults = assessmentHistory
        assessmentHistory.append(completedResult)
        assessmentHistory = Array(assessmentHistory.suffix(20))
        rehabilitationProfile = RehabilitationProfileAnalyzer.makeProfile(
            from: completedResult,
            previousResults: previousResults
        )
        if let data = try? JSONEncoder().encode(assessmentHistory) {
            UserDefaults.standard.set(data, forKey: historyStorageKey)
        }
    }

    private func stopTracking() {
        trackingRunID = UUID()
        trackingTask?.cancel()
        trackingTask = nil
        arSession.stop()
    }
}

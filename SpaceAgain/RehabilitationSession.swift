import ARKit
import Foundation
import QuartzCore
import simd

enum RehabilitationCueProtocol {
    // Evidence-informed prototype schedule. A recent VR neglect-training
    // protocol blinked an unattended target after 10 seconds. The subsequent
    // three-second interval reflects the short cue durations used in related
    // VR work; neither value is a universal diagnostic or treatment cut-off.
    static let initialCueDelay: TimeInterval = 10
    static let escalationInterval: TimeInterval = 3
    static let strongCueDelay = initialCueDelay + escalationInterval
    static let pulseInterval: Duration = .milliseconds(500)
}

@MainActor
final class RehabilitationSession: ObservableObject {
    static let immersiveSpaceID = "spatial-rehabilitation"

    enum Phase: Equatable { case ready, launching, training, finishing, summary }
    enum CueLevel: Int, Comparable {
        case none, subtle, strong
        static func < (lhs: CueLevel, rhs: CueLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var pathway: RehabilitationPathway = .orientation
    @Published private(set) var affectedSide: AffectedSide = .uncertain
    @Published private(set) var activeItems: [RehabilitationItem] = []
    @Published private(set) var selectedItemIDs: Set<UUID> = []
    @Published private(set) var cueLevel: CueLevel = .none
    @Published private(set) var trialNumber = 0
    @Published private(set) var trialCount = 0
    @Published private(set) var summary: RehabilitationSummary?
    @Published private(set) var trackingNotice: String?
    @Published private(set) var isSimulatorDemo = false

    private var arSession = ARKitSession()
    private var trackingRunID = UUID()
    private var trackingTask: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?
    private var initialForward = SIMD3<Float>(0, 0, -1)
    private var hasInitialPose = false
    private var startTime: TimeInterval = 0
    private var trialStartTime: TimeInterval = 0
    private var firstAffectedTime: TimeInterval?
    private var maximumAffectedExcursion = 0.0
    private var coveredBins: Set<Int> = []
    private var uncuedSuccesses = 0
    private var orientationTargetsFound = 0
    private var cueCount = 0
    private var orientationAngles: [Double] = []
    private var orientationElevations: [Double] = []

    var targetCount: Int {
        pathway == .orientation ? trialCount : activeItems.filter(\.isTarget).count
    }

    var targetsFound: Int {
        pathway == .orientation ? orientationTargetsFound : activeItems.filter {
            $0.isTarget && selectedItemIDs.contains($0.id)
        }.count
    }

    var cuedItemID: UUID? {
        guard cueLevel != .none else { return nil }
        let remainingTargets = activeItems.filter {
            $0.isTarget && !selectedItemIDs.contains($0.id)
        }
        if pathway == .orientation { return remainingTargets.first?.id }
        // Exploration starts from the affected-side boundary, so cue the
        // outermost remaining target rather than making every target blink.
        return remainingTargets.max { abs($0.angleDegrees) < abs($1.angleDegrees) }?.id
    }

    var cueMessage: String? {
        guard cueLevel != .none else { return nil }
        let side = affectedSide.displayName.lowercased()
        switch pathway {
        case .orientation:
            return cueLevel == .subtle
                ? "Begin turning \(side)."
                : "Turn your head toward the \(side) target."
        default:
            return cueLevel == .subtle
                ? "Return to the \(side) boundary."
                : "Start at the \(side) edge, then sweep each row systematically."
        }
    }

    func prepare(profile: SpatialRehabilitationProfile, pathway chosenPathway: RehabilitationPathway) {
        stopTasks()
        affectedSide = profile.affectedSide
        pathway = chosenPathway == .blended ? .orientation : chosenPathway
        phase = .launching
        summary = nil
        selectedItemIDs = []
        cueLevel = .none
        trialNumber = 0
        resetMetrics()

        if pathway == .orientation {
            let direction = affectedSide.direction
            orientationAngles = [22, 32, 42, 52, 62, 72, 48, 66].map { $0 * direction }
            orientationElevations = [0, 18, -16, 28, -24, 8, -6, 22]
            trialCount = orientationAngles.count
            advanceOrientationTrial()
        } else {
            activeItems = makeExplorationItems()
            trialCount = activeItems.filter(\.isTarget).count
        }
    }

    func cancelLaunch() {
        stopTasks()
        phase = .ready
    }

    func start() async {
        guard phase == .launching else { return }
        let runID = trackingRunID
        let session = ARKitSession()
        arSession = session
        startTime = CACurrentMediaTime()
        trialStartTime = startTime
        phase = .training
        startCueMonitoring()

#if targetEnvironment(simulator)
        isSimulatorDemo = true
        trackingNotice = "DEMO MODE: simulator camera rotation is treated as synthetic head movement. These measurements are arbitrary and not clinically valid."
#else
        isSimulatorDemo = false
#endif

        guard WorldTrackingProvider.isSupported else {
            trackingNotice = "Head tracking is unavailable. Training can continue, but pathway metrics will not be recorded."
            return
        }

        // ARKit providers cannot be run again after the session stops them.
        // Keep a fresh provider local to this run, including its sampling task.
        let worldTracking = WorldTrackingProvider()
        do {
            try await session.run([worldTracking])
            guard trackingRunID == runID, phase == .training else {
                session.stop()
                return
            }
            trackingTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.trackingRunID == runID else { return }
                    let timestamp = CACurrentMediaTime()
                    if worldTracking.state == .running,
                       let anchor = worldTracking.queryDeviceAnchor(atTimestamp: timestamp), anchor.isTracked {
                        self.process(anchor.originFromAnchorTransform, at: timestamp)
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        } catch {
            guard trackingRunID == runID else { return }
            trackingNotice = "Head tracking could not be started. Please review device permissions and fit."
        }
    }

    @discardableResult
    func select(itemID: UUID) -> Bool {
        guard phase == .training,
              let item = activeItems.first(where: { $0.id == itemID }),
              !selectedItemIDs.contains(itemID) else { return false }
        selectedItemIDs.insert(itemID)
        guard item.isTarget else { return true }

        if cueLevel == .none { uncuedSuccesses += 1 }
        if pathway == .orientation {
            orientationTargetsFound += 1
            if orientationTargetsFound >= trialCount {
                finish()
            } else {
                advanceOrientationTrial()
            }
        } else {
            // Give the user a fresh uncued search interval for each target.
            cueLevel = .none
            trialStartTime = CACurrentMediaTime()
        }
        return true
    }

    func finish() {
        guard phase == .training else { return }
        phase = .finishing
        let duration = max(0, CACurrentMediaTime() - startTime)
        let found = pathway == .orientation
            ? orientationTargetsFound
            : activeItems.filter { $0.isTarget && selectedItemIDs.contains($0.id) }.count
        stopTasks()
        summary = RehabilitationSummary(
            completedAt: Date(),
            pathway: pathway,
            affectedSide: affectedSide,
            targetsFound: found,
            targetCount: targetCount,
            uncuedSuccesses: uncuedSuccesses,
            cueCount: cueCount,
            affectedInitiationLatency: firstAffectedTime,
            maximumAffectedExcursion: maximumAffectedExcursion,
            coveredBins: coveredBins,
            duration: duration
        )
        phase = .summary
    }

    func reset() {
        stopTasks()
        activeItems = []
        selectedItemIDs = []
        summary = nil
        phase = .ready
    }

    private func advanceOrientationTrial() {
        guard trialNumber < trialCount else { return }
        let index = trialNumber
        trialNumber += 1
        selectedItemIDs = []
        cueLevel = .none
        trialStartTime = CACurrentMediaTime()
        activeItems = [RehabilitationItem(
            id: UUID(),
            angleDegrees: orientationAngles[index],
            elevationDegrees: orientationElevations[index],
            isTarget: true,
            variant: 0
        )]
    }

    private func makeExplorationItems() -> [RehabilitationItem] {
        let direction = affectedSide.direction
        let magnitudes = [76.0, 64, 52, 40, 28, 16, 4]
        let elevations = [30.0, 4, -24]
        let targetSlots: Set<Int> = [0, 5, 9, 13, 16, 20]
        var items: [RehabilitationItem] = []
        var slot = 0
        for elevation in elevations {
            for magnitude in magnitudes {
                items.append(RehabilitationItem(
                    id: UUID(),
                    angleDegrees: magnitude * direction,
                    elevationDegrees: elevation,
                    isTarget: targetSlots.contains(slot),
                    variant: slot % 4
                ))
                slot += 1
            }
        }
        return items
    }

    private func startCueMonitoring() {
        cueTask?.cancel()
        cueTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.phase == .training else { return }
                let elapsed = CACurrentMediaTime() - self.trialStartTime
                let nextLevel: CueLevel = elapsed >= RehabilitationCueProtocol.strongCueDelay
                    ? .strong
                    : (elapsed >= RehabilitationCueProtocol.initialCueDelay ? .subtle : .none)
                if nextLevel > self.cueLevel {
                    self.cueLevel = nextLevel
                    self.cueCount += 1
                }
            }
        }
    }

    private func process(_ transform: simd_float4x4, at timestamp: TimeInterval) {
        let forward = horizontalForward(from: transform)
        if !hasInitialPose {
            initialForward = forward
            hasInitialPose = true
            return
        }

        let cross = simd_cross(initialForward, forward)
        let dot = max(-1, min(1, simd_dot(initialForward, forward)))
        let angle = -Double(atan2(cross.y, dot) * 180 / .pi)
        let bin = min(90, max(-90, Int((angle / 15).rounded()) * 15))
        let inserted = coveredBins.insert(bin).inserted
        if inserted, pathway == .exploration {
            trialStartTime = timestamp
            cueLevel = .none
        }

        let affectedExcursion = affectedSide == .left ? max(0, -angle) : max(0, angle)
        maximumAffectedExcursion = max(maximumAffectedExcursion, affectedExcursion)
        if affectedExcursion >= 8, firstAffectedTime == nil {
            firstAffectedTime = max(0, timestamp - startTime)
        }
    }

    private func horizontalForward(from transform: simd_float4x4) -> SIMD3<Float> {
        var forward = -SIMD3<Float>(transform.columns.2.x, 0, transform.columns.2.z)
        if simd_length_squared(forward) < 0.0001 { forward = SIMD3<Float>(0, 0, -1) }
        return simd_normalize(forward)
    }

    private func resetMetrics() {
        trackingNotice = nil
        isSimulatorDemo = false
        startTime = 0
        trialStartTime = 0
        firstAffectedTime = nil
        maximumAffectedExcursion = 0
        coveredBins = []
        uncuedSuccesses = 0
        orientationTargetsFound = 0
        cueCount = 0
        hasInitialPose = false
        initialForward = SIMD3<Float>(0, 0, -1)
    }

    private func stopTasks() {
        trackingRunID = UUID()
        trackingTask?.cancel()
        trackingTask = nil
        cueTask?.cancel()
        cueTask = nil
        arSession.stop()
    }
}

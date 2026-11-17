import Charts
import SwiftUI

struct ResultsView: View {
    let result: AssessmentResult
    let profile: SpatialRehabilitationProfile?
    let restart: () -> Void
    let startRehabilitation: (RehabilitationPathway) -> Void
    let startSimulatorDemo: (AffectedSide, RehabilitationPathway) -> Void

    private var leftSectors: [SectorResult] { Array(result.sectorResults.prefix(3)) }
    private var rightSectors: [SectorResult] { Array(result.sectorResults.suffix(3)) }
    private var leftAvailable: Int { leftSectors.reduce(0) { $0 + $1.targetsAvailable } }
    private var rightAvailable: Int { rightSectors.reduce(0) { $0 + $1.targetsAvailable } }
    private var leftDetected: Int { leftSectors.reduce(0) { $0 + $1.targetsCancelled } }
    private var rightDetected: Int { rightSectors.reduce(0) { $0 + $1.targetsCancelled } }
    private var leftDetectionPercentage: Double { percentage(leftDetected, of: leftAvailable) }
    private var rightDetectionPercentage: Double { percentage(rightDetected, of: rightAvailable) }
    private var targetsMissed: Int { result.targetCount - result.targetsFound }

    private var trackingSource: HeadTrackingSource? {
        if let source = result.headTrackingSource { return source }
        return result.headTrackingWasReliable == true ? .visionPro : nil
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Assessment Results")
                    .font(.title.bold())

                if trackingSource == .simulatorCamera {
                    Label("Demo · Simulated movement, not clinical data", systemImage: "desktopcomputer")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                targetDetectionSection
                Divider()
                headMovementSection
                Divider()
                explorationEvidenceSection
                responseBehaviourSection
                additionalObservationsSection
                Divider()
                rehabilitationRecommendationSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 64)
            .frame(maxWidth: 1_180)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.visible)
        .defaultScrollAnchor(.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rehabilitationRecommendationSection: some View {
        resultSection(
            title: "Recommended next step",
            description: "Prototype suggestion · Therapist confirmation required"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let profile {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: pathwayIcon(profile.recommendedPathway))
                            .font(.title)
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.recommendedPathway.displayName)
                                .font(.title3.bold())
                            Text(recommendationHeadline(profile))
                                .font(.headline)
                        }
                    }

                    DisclosureGroup("Why this pathway?") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Prototype scores: A \(percent(profile.orientationNeed * 100)) · B \(percent(profile.explorationNeed * 100))")
                            Text(pathwayReason(profile))
                            Text("Algorithm consistency: \(consistencyLabel(profile.confidence)). Based on \(profile.assessmentCount) saved assessments.")
                                .foregroundStyle(.secondary)
                            Text("Scores use provisional rules, not clinical severity or probabilities.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.top, 8)
                    }

                    if profile.canBeginTraining && profile.hasUsableTrackingForCurrentRun {
                        Button {
                            startRehabilitation(profile.recommendedPathway)
                        } label: {
                            Label("Begin Recommended Training", systemImage: "play.fill")
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
                        .font(.callout)
                    } else {
                        Label(
                            profile.hasUsableTrackingForCurrentRun
                                ? "No side-specific immersive pathway is automatically assigned."
                                : "Reliable Vision Pro head tracking is required before automatic pathway assignment.",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    }

                } else {
                    Text("A recommendation could not be generated from this assessment.")
                        .foregroundStyle(.secondary)
                }

#if targetEnvironment(simulator)
                simulatorDemoControls
#endif

                Button("Start New Assessment", action: restart)
                    .buttonStyle(.bordered)
            }
            .padding(16)
            .glassBackgroundEffect()
        }
    }

    private func pathwayReason(_ profile: SpatialRehabilitationProfile) -> String {
        switch profile.recommendedPathway {
        case .orientation:
            "The Orientation score is higher. Begin with practice initiating movement toward the difficult side."
        case .exploration:
            "The Exploration score is at least as high as Orientation. Begin with systematic scanning practice."
        case .blended:
            "Both scores are at least 45% and less than 18 percentage points apart. Begin with Orientation, then consider Exploration."
        case .notIndicated:
            "The current rules did not identify a clear lateral pattern for automatic side-specific training."
        case .clinicianReview:
            "The side pattern or tracking data does not support automatic pathway assignment. Review the measurements before choosing training."
        }
    }

#if targetEnvironment(simulator)
    private var simulatorDemoControls: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Manual controls for development only. Choose the difficulty side and exercise directly.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                HStack {
                    Button("Left · Orientation") { startSimulatorDemo(.left, .orientation) }
                    Button("Left · Exploration") { startSimulatorDemo(.left, .exploration) }
                }
                HStack {
                    Button("Right · Orientation") { startSimulatorDemo(.right, .orientation) }
                    Button("Right · Exploration") { startSimulatorDemo(.right, .exploration) }
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 10)
        } label: {
            Label("Developer demo controls", systemImage: "wrench.and.screwdriver")
        }
        .font(.callout)
        .padding(.top, 4)
    }
#endif

    private func recommendationHeadline(_ profile: SpatialRehabilitationProfile) -> String {
        profile.canBeginTraining
            ? "Focus on the \(profile.affectedSide.displayName.lowercased()) side"
            : "No clear side-specific pattern"
    }

    private func consistencyLabel(_ confidence: Double) -> String {
        switch confidence {
        case 0.75...: "High"
        case 0.50..<0.75: "Moderate"
        default: "Low"
        }
    }

    private func pathwayIcon(_ pathway: RehabilitationPathway) -> String {
        switch pathway {
        case .orientation: "arrow.turn.up.left"
        case .exploration: "rectangle.grid.3x2"
        case .blended: "arrow.triangle.branch"
        case .notIndicated: "checkmark.circle"
        case .clinicianReview: "person.crop.circle.badge.questionmark"
        }
    }

    private var summarySection: some View {
        resultSection(
            title: "Spatial Exploration Summary",
            description: "An automatic description combining detection, response behaviour, and recorded head movement."
        ) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(interpretation)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var targetDetectionSection: some View {
        resultSection(
            title: "1. Which side was harder?",
            description: profile.map { recommendationHeadline($0) } ?? "Compare left and right detection"
        ) {
            HStack(spacing: 10) {
                compactMetric("Bells found", "\(result.targetsFound) / \(result.targetCount)")
                compactMetric("Left found", "\(leftDetected) / \(leftAvailable)", highlighted: profile?.affectedSide == .left)
                compactMetric("Right found", "\(rightDetected) / \(rightAvailable)", highlighted: profile?.affectedSide == .right)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Detection by sector").font(.callout.weight(.semibold))
                Chart(result.sectorResults) { sectorResult in
                    BarMark(
                        x: .value("Sector", sectorResult.sector.displayName),
                        y: .value("Detection", sectorResult.detectionPercentage)
                    )
                    .foregroundStyle(sectorColor(sectorResult.sector).gradient)
                    .cornerRadius(7)
                    .annotation(position: .top, spacing: 5) {
                        Text("\(sectorResult.targetsCancelled)/\(sectorResult.targetsAvailable)")
                            .font(.caption.bold())
                    }
                }
                .chartYScale(domain: 0 ... 110)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let percentage = value.as(Int.self) {
                                Text("\(percentage)%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let label = value.as(String.self) {
                                Text(label.replacingOccurrences(of: "° to ", with: "…"))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 170)
                .allowsHitTesting(false)

                HStack {
                    Text("LEFT").foregroundStyle(.blue)
                    Spacer()
                    Text("0°").foregroundStyle(.secondary)
                    Spacer()
                    Text("RIGHT").foregroundStyle(.orange)
                }
                .font(.caption.bold())
            }
            .padding(14)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var responseBehaviourSection: some View {
        resultSection(
            title: "Selection timing",
            description: "Supporting observation · Time from test start to selection"
        ) {
            HStack(spacing: 12) {
                responseMetric(
                    title: "Mean left response",
                    value: formatted(result.meanLeftResponseTime),
                    highlighted: slowerResponseSide == .left
                )
                responseMetric(
                    title: "Mean right response",
                    value: formatted(result.meanRightResponseTime),
                    highlighted: slowerResponseSide == .right
                )
            }
            Text(responseComparison).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var headMovementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("2. Orientation A · Turning toward the side")
                    .font(.title3.bold())
                Spacer()
                if let profile, profile.canBeginTraining, profile.hasUsableTrackingForCurrentRun {
                    Text("A score \(percent(profile.orientationNeed * 100))")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
            }
            if trackingSource != nil {
                HStack(alignment: .top, spacing: 12) {
                    movementComparison(
                        "First turn after",
                        left: formatted(result.timeBeforeFirstLeftExploration),
                        right: formatted(result.timeBeforeFirstRightExploration),
                        highlighted: laterTurnSide
                    )
                    movementComparison(
                        "Furthest turn",
                        left: degrees(result.maximumLeftExplorationDegrees),
                        right: degrees(result.maximumRightExplorationDegrees),
                        highlighted: smallerRangeSide
                    )
                    movementComparison(
                        "Time facing side",
                        left: formatted(result.leftExplorationTime),
                        right: formatted(result.rightExplorationTime),
                        highlighted: shorterDwellSide
                    )
                }
                HStack {
                    Text("First scan: \(result.firstScanningDirection.displayName)")
                    Spacer()
                    Text("Highlights show the comparison, not a diagnosis")
                }
                .font(.caption).foregroundStyle(.secondary)
                HeadExplorationRange(
                    maximumLeft: result.maximumLeftExplorationDegrees,
                    maximumRight: result.maximumRightExplorationDegrees,
                    angularDwellSeconds: result.angularDwellSeconds
                )
                .frame(height: 128)
                .padding(16)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                DisclosureGroup("How is A calculated?") {
                    if let profile, profile.canBeginTraining, profile.hasUsableTrackingForCurrentRun {
                        Text("Prototype score: \(percent(profile.orientationNeed * 100))")
                            .font(.callout.weight(.semibold))
                            .padding(.top, 8)
                    }
                    Text("Turn-range difference 45% · time difference 35% · first-turn delay 20%. Less or later movement toward the difficult side increases the score. These weights are provisional.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } else {
                Label("Not recorded / Requires Vision Pro", systemImage: "visionpro.slash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassBackgroundEffect()
            }
        }
    }

    private var explorationEvidenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. Exploration B · Finding bells")
                .font(.title3.bold())
            if let profile, profile.canBeginTraining {
                let isLeft = profile.affectedSide == .left
                let available = isLeft ? leftAvailable : rightAvailable
                let omissions = isLeft ? result.leftOmissions : result.rightOmissions
                HStack(spacing: 12) {
                    compactMetric("\(profile.affectedSide.displayName) bells missed", "\(omissions) / \(available)", highlighted: omissions > 0)
                    compactMetric("\(profile.affectedSide.displayName) found", "\(isLeft ? leftDetected : rightDetected) / \(available)")
                    if profile.hasUsableTrackingForCurrentRun {
                        compactMetric("Prototype B score", percent(profile.explorationNeed * 100))
                    }
                }
                DisclosureGroup("How is B calculated?") {
                    if profile.hasUsableTrackingForCurrentRun {
                        Text("Prototype score: \(percent(profile.explorationNeed * 100))")
                            .font(.callout.weight(.semibold))
                            .padding(.top, 8)
                    }
                    Text("Missed bells on the difficult side, weighted by head-turn range and time shown above. More misses increase the score. Movement does not confirm that a target was seen. This calculation is provisional.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } else {
                Text("A difficulty side must be established before a side-specific Exploration score can be interpreted.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var laterTurnSide: Side? {
        guard let left = result.timeBeforeFirstLeftExploration,
              let right = result.timeBeforeFirstRightExploration else { return nil }
        return left == right ? nil : (left > right ? .left : .right)
    }

    private var smallerRangeSide: Side? {
        let left = result.maximumLeftExplorationDegrees
        let right = result.maximumRightExplorationDegrees
        return left == right ? nil : (left < right ? .left : .right)
    }

    private var shorterDwellSide: Side? {
        let left = result.leftExplorationTime
        let right = result.rightExplorationTime
        return left == right ? nil : (left < right ? .left : .right)
    }

    private func movementComparison(_ title: String, left: String, right: String, highlighted: Side?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                movementValue("Left", value: left, highlighted: highlighted == .left)
                movementValue("Right", value: right, highlighted: highlighted == .right)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func movementValue(_ side: String, value: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(side).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(highlighted ? Color.yellow.opacity(0.13) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(highlighted ? Color.yellow.opacity(0.65) : Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var additionalObservationsSection: some View {
        DisclosureGroup("Additional assessment details") {
            VStack(alignment: .leading, spacing: 16) {
            Text("Supporting observations · These do not directly select the pathway.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                compactMetric("Bells missed", "\(targetsMissed)")
                compactMetric("Incorrect selections", "\(result.falsePositiveCount)")
            }
            detailedSectorSection
            DisclosureGroup("Written summary") { summarySection.padding(.top, 8) }
            }
            .padding(.top, 12)
        }
    }

    private var detailedSectorSection: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Sector")
                    Text("Detected")
                    Text("Missed")
                    Text("Detection")
                    Text("Mean response")
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)

                ForEach(result.sectorResults) { sectorResult in
                    GridRow {
                        Text(sectorResult.sector.displayName)
                        Text("\(sectorResult.targetsCancelled) / \(sectorResult.targetsAvailable)")
                        Text("\(sectorResult.omissions)")
                        Text(percent(sectorResult.detectionPercentage))
                        Text(formatted(sectorResult.meanResponseTime))
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 14)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Detailed Sector Data").font(.headline)
                Text("Expand to review exact detection and response values for every sector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassBackgroundEffect()
    }

    private func resultSection<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold())
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func compactMetric(_ title: String, _ value: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(highlighted ? Color.yellow.opacity(0.13) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(highlighted ? Color.yellow.opacity(0.65) : Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private func responseMetric(title: String, value: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(
            highlighted ? Color.yellow.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(highlighted ? Color.yellow.opacity(0.65) : Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var interpretation: String {
        let detectionDifference = leftDetectionPercentage - rightDetectionPercentage
        let detectionClause: String
        if detectionDifference <= -15 {
            detectionClause = "Fewer targets were detected in the left hemispace (\(percent(leftDetectionPercentage)) vs \(percent(rightDetectionPercentage)) right)"
        } else if detectionDifference >= 15 {
            detectionClause = "Fewer targets were detected in the right hemispace (\(percent(rightDetectionPercentage)) vs \(percent(leftDetectionPercentage)) left)"
        } else {
            detectionClause = "Target detection was broadly balanced between left and right space"
        }

        var observations = [detectionClause]
        if let left = result.meanLeftResponseTime, let right = result.meanRightResponseTime {
            if left - right >= 2 {
                observations.append("left-side targets were selected more slowly")
            } else if right - left >= 2 {
                observations.append("right-side targets were selected more slowly")
            } else {
                observations.append("response times were similar between sides")
            }
        } else {
            observations.append("there were insufficient detections to compare response times")
        }

        if let trackingSource {
            let leftReach = result.maximumLeftExplorationDegrees
            let rightReach = result.maximumRightExplorationDegrees
            if leftReach + 15 < rightReach {
                observations.append("recorded head exploration extended less far to the left")
            } else if rightReach + 15 < leftReach {
                observations.append("recorded head exploration extended less far to the right")
            } else {
                observations.append("maximum head orientation was similar in both directions")
            }
            if trackingSource == .simulatorCamera {
                observations.append("movement values came from arbitrary simulator camera control and are for demonstration only")
            }
        } else {
            observations.append("head movement was not recorded and requires Vision Pro")
        }

        return observations.enumerated().map { index, observation in
            index == 0 ? observation : observation.lowercased()
        }.joined(separator: "; ") + "."
    }

    private enum Side { case left, right }

    private var slowerResponseSide: Side? {
        guard let left = result.meanLeftResponseTime,
              let right = result.meanRightResponseTime,
              abs(left - right) >= 2 else { return nil }
        return left > right ? .left : .right
    }

    private var responseComparison: String {
        switch slowerResponseSide {
        case .left: "Longer mean response on the left"
        case .right: "Longer mean response on the right"
        case nil: "No marked left/right difference"
        }
    }

    private func percentage(_ detected: Int, of available: Int) -> Double {
        available == 0 ? 0 : Double(detected) / Double(available) * 100
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
    private func degrees(_ value: Double) -> String { String(format: "%.0f°", value) }
    private func formatted(_ value: TimeInterval?) -> String { value.map { formatted($0) } ?? "Not recorded" }
    private func formatted(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }

    private func sectorColor(_ sector: SpatialSector) -> Color {
        switch sector {
        case .farLeft, .midLeft, .nearLeft: .blue
        case .center: .green
        case .nearRight, .midRight, .farRight: .orange
        }
    }
}

private struct HeadExplorationRange: View {
    let maximumLeft: Double
    let maximumRight: Double
    let angularDwellSeconds: [Int: TimeInterval]

    private let bins = Array(stride(from: -90, through: 90, by: 15))

    private var maximumDwell: TimeInterval {
        max(angularDwellSeconds.values.max() ?? 0, 0.001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Head-turn coverage")
                .font(.caption.bold())
            Text("15° bands · Brighter = more time · Blank = no valid samples")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                ForEach(bins, id: \.self) { bin in
                    let duration = angularDwellSeconds[bin, default: 0]
                    RoundedRectangle(cornerRadius: 4)
                        .fill(duration > 0 ? color(for: bin).opacity(opacity(for: duration)) : .white.opacity(0.08))
                        .overlay {
                            if bin == 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.white.opacity(0.85), lineWidth: 2)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .accessibilityLabel("\(bin) degrees")
                        .accessibilityValue(duration > 0 ? String(format: "%.1f seconds", duration) : "No valid samples")
                }
            }

            HStack {
                Text("−90° LEFT")
                Spacer()
                Text("0°")
                Spacer()
                Text("RIGHT +90°")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(
                "Single-sample extrema: left −\(Int(maximumLeft.rounded()))° · right +\(Int(maximumRight.rounded()))°"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func color(for bin: Int) -> Color {
        if bin < 0 { return .blue }
        if bin > 0 { return .orange }
        return .green
    }

    private func opacity(for duration: TimeInterval) -> Double {
        0.25 + 0.75 * min(1, duration / maximumDwell)
    }
}

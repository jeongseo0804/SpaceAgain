import RealityKit
import SwiftUI
import UIKit

private struct AssessmentStimulusComponent: Component {}

struct ImmersiveAssessmentView: View {
    @EnvironmentObject private var assessment: AssessmentSession
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var isRetryingCalibration = false

    private let finishAttachmentID = "finish-assessment-control"
    private let calibrationAttachmentID = "head-orientation-calibration"
    private let trackingWarningAttachmentID = "assessment-tracking-warning"
    private let simulatorNoticeAttachmentID = "simulator-tracking-notice"
    private let contentRootName = "AssessmentContentRoot"
    private let calibrationContentName = "CalibrationContent"
    private let stimulusContentName = "StimulusContent"

    var body: some View {
        RealityView { content, attachments in
            AssessmentStimulusComponent.registerComponent()
            // Keep the field in world space so the captured baseline can set its centre.
            let initialPoseAnchor = AnchorEntity(world: .zero)
            initialPoseAnchor.name = "InitialHeadPose"
            let root = Entity()
            root.name = contentRootName
            populateCurrentContent(in: root)
            initialPoseAnchor.addChild(root)
            content.add(initialPoseAnchor)

            let headAnchor = AnchorEntity(.head, trackingMode: .continuous)
            // Keep the stillness instructions visible as the user moves.
            let calibrationAnchor = AnchorEntity(.head, trackingMode: .continuous)
            if let calibration = attachments.entity(for: calibrationAttachmentID) {
                calibration.position = SIMD3<Float>(0, -0.12, -0.82)
                calibrationAnchor.addChild(calibration)
            }
            content.add(calibrationAnchor)
            if let finishControl = attachments.entity(for: finishAttachmentID) {
                finishControl.position = SIMD3<Float>(0, -0.32, -0.75)
                headAnchor.addChild(finishControl)
            }
            if let warning = attachments.entity(for: trackingWarningAttachmentID) {
                warning.position = SIMD3<Float>(0, 0.28, -0.78)
                headAnchor.addChild(warning)
            }
#if targetEnvironment(simulator)
            if let notice = attachments.entity(for: simulatorNoticeAttachmentID) {
                notice.position = SIMD3<Float>(0, 0.42, -0.78)
                headAnchor.addChild(notice)
            }
#endif
            content.add(headAnchor)
        } update: { content, _ in
            guard let root = content.entities
                .compactMap({ $0.findEntity(named: contentRootName) })
                .first else { return }
            if let baseline = assessment.initialDeviceTransform {
                let forward = -SIMD3<Float>(baseline.columns.2.x, 0, baseline.columns.2.z)
                let yaw = atan2(-forward.x, -forward.z)
                root.position = SIMD3<Float>(baseline.columns.3.x, baseline.columns.3.y, baseline.columns.3.z)
                root.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            }
            let desiredName = assessment.phase == .assessing
                ? stimulusContentName
                : calibrationContentName
            guard root.children.first?.name != desiredName else { return }
            for child in Array(root.children) { child.removeFromParent() }
            populateCurrentContent(in: root)
        } attachments: {
            Attachment(id: calibrationAttachmentID) {
                if assessment.phase == .calibrating {
                    calibrationPanel
                }
            }

            Attachment(id: finishAttachmentID) {
                if assessment.phase == .assessing {
                    Button("I’m Finished") {
                        Task { @MainActor in
                            if assessment.finishAssessment() {
                                await dismissImmersiveSpace()
                                openWindow(id: AssessmentSession.mainWindowID)
                            }
                        }
                    }
                    .disabled(!assessment.isHeadTrackingAvailable)
                    .font(.title3.bold())
                    .buttonStyle(.borderedProminent)
                    .padding(12)
                    .glassBackgroundEffect()
                }
            }

            Attachment(id: trackingWarningAttachmentID) {
                if assessment.phase == .assessing, !assessment.isHeadTrackingAvailable {
                    VStack(spacing: 6) {
                        Label(
                            AssessmentSession.trackingUnavailableMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.title3.bold())
                        Text("Assessment data collection is paused.")
                            .font(.headline)
                    }
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 620)
                    .glassBackgroundEffect()
                }
            }

#if targetEnvironment(simulator)
            Attachment(id: simulatorNoticeAttachmentID) {
                if assessment.phase == .calibrating || assessment.phase == .assessing {
                    Label(
                        "SIMULATED CALIBRATION · Camera rotation is synthetic head movement",
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                    )
                    .font(.callout.bold())
                    .foregroundStyle(.orange)
                    .padding(12)
                    .glassBackgroundEffect()
                }
            }
#endif
        }
        .gesture(
            SpatialTapGesture()
                .targetedToEntity(where: .has(AssessmentStimulusComponent.self))
                .onEnded { value in
                    guard let itemID = UUID(uuidString: value.entity.name) else { return }
                    if assessment.select(itemID: itemID) {
                        applySelectedAppearance(to: value.entity)
                    }
                }
        )
        .task { await assessment.startCalibration() }
        .onDisappear {
            if assessment.phase == .calibrating || assessment.phase == .assessing {
                assessment.reset()
                openWindow(id: AssessmentSession.mainWindowID)
            }
        }
    }

    private var calibrationPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.system(size: 38, weight: .semibold))
            Text(calibrationTitle)
                .font(.largeTitle.bold())
            Text(calibrationInstruction)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Label(calibrationStatusText, systemImage: calibrationStatusIcon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(calibrationStatusColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

            if assessment.calibrationStatus == .holdingPosition,
               abs(assessment.calibrationAngleDegrees) <= AssessmentSession.calibrationInnerToleranceDegrees {
                ProgressView(value: assessment.calibrationProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                Text("Hold still for 5 seconds")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                assessment.beginAssessmentAfterCalibration()
            } label: {
                Label("Begin Assessment", systemImage: "play.fill")
                    .font(.title3.bold())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!assessment.canBeginAssessment)

            if let error = assessment.trackingStartupError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.yellow)
            }
            if !assessment.isHeadTrackingAvailable {
                Text("Tracking is reconnecting. The timer pauses briefly; a longer interruption restarts the five-second hold.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Restart Calibration") {
                isRetryingCalibration = true
                Task { @MainActor in
                    await assessment.retryCalibration()
                    isRetryingCalibration = false
                }
            }
            .disabled(isRetryingCalibration)
            .buttonStyle(.bordered)
        }
        .padding(28)
        .frame(width: 620)
        .glassBackgroundEffect()
    }

    private var calibrationTitle: String {
        assessment.calibrationStatus == .confirmed ? "Position Confirmed" : "Please Face Forward"
    }

    private var calibrationInstruction: String {
        assessment.calibrationStatus == .confirmed
            ? "Your neutral forward-facing direction is calibrated."
            : "Face a comfortable forward direction and hold still for 5 seconds to set your baseline."
    }

    private var calibrationStatusText: String {
        switch assessment.calibrationStatus {
        case .acquiringTracking:
            "Detecting your head position…"
        case .needsAlignment:
            "Hold your head still to set your baseline."
        case .holdingPosition:
            abs(assessment.calibrationAngleDegrees) <= AssessmentSession.calibrationInnerToleranceDegrees
                ? "Keep still while your baseline is captured."
                : "Hold your head still."
        case .confirmed:
            assessment.isHeadTrackingAvailable
                ? "Position confirmed. You may begin."
                : "Baseline saved. Waiting for head tracking to reconnect…"
        case .trackingUnavailable:
            AssessmentSession.trackingUnavailableMessage
        }
    }

    private var calibrationStatusIcon: String {
        switch assessment.calibrationStatus {
        case .confirmed: assessment.isHeadTrackingAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .trackingUnavailable: "exclamationmark.triangle.fill"
        case .needsAlignment: "exclamationmark.circle"
        case .acquiringTracking, .holdingPosition: "viewfinder"
        }
    }

    private var calibrationStatusColor: Color {
        switch assessment.calibrationStatus {
        case .confirmed: assessment.isHeadTrackingAvailable ? .green : .yellow
        case .trackingUnavailable, .needsAlignment: .yellow
        case .acquiringTracking, .holdingPosition: .primary
        }
    }

    private func populateCurrentContent(in root: Entity) {
        let container = Entity()
        if assessment.phase == .assessing {
            container.name = stimulusContentName
            populateStimuli(in: container)
        } else {
            container.name = calibrationContentName
            container.addChild(makeCentreMarker())
        }
        root.addChild(container)
    }

    private func makeCentreMarker() -> Entity {
        let root = Entity()
        root.name = "CentreMarker"
        root.position = SIMD3<Float>(0, 0.14, -1.0)
        let material = UnlitMaterial(color: UIColor(white: 0.96, alpha: 1))
        let accent = UnlitMaterial(color: UIColor(red: 0.98, green: 0.78, blue: 0.20, alpha: 1))

        let dot = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [accent])
        root.addChild(dot)

        let cornerOffset: Float = 0.075
        let barLength: Float = 0.050
        let thickness: Float = 0.008
        for x: Float in [-1, 1] {
            for y: Float in [-1, 1] {
                let horizontal = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(barLength, thickness, thickness), cornerRadius: 0.003),
                    materials: [material]
                )
                horizontal.position = SIMD3<Float>(x * (cornerOffset - barLength / 2), y * cornerOffset, 0)
                root.addChild(horizontal)

                let vertical = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(thickness, barLength, thickness), cornerRadius: 0.003),
                    materials: [material]
                )
                vertical.position = SIMD3<Float>(x * cornerOffset, y * (cornerOffset - barLength / 2), 0)
                root.addChild(vertical)
            }
        }
        return root
    }

    private func populateStimuli(in anchor: Entity) {
        for item in assessment.items {
            let radians = Float(item.angleDegrees * .pi / 180)
            let horizontalRadius = sqrt(max(
                0,
                item.radiusMeters * item.radiusMeters
                    - item.verticalOffsetMeters * item.verticalOffsetMeters
            ))
            let stimulus = makeStimulus(for: item)
            stimulus.position = SIMD3<Float>(
                sin(radians) * horizontalRadius,
                item.verticalOffsetMeters - 0.08,
                -cos(radians) * horizontalRadius
            )
            stimulus.orientation = simd_quatf(angle: -radians, axis: SIMD3<Float>(0, 1, 0))
            anchor.addChild(stimulus)
        }
    }

    private func makeStimulus(for item: AssessmentItem) -> Entity {
        let root = Entity()
        root.name = item.id.uuidString
        root.components.set(AssessmentStimulusComponent())
        root.scale = SIMD3<Float>(repeating: 0.65)
        root.components.set(InputTargetComponent())
        root.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.062)]))

        let material = UnlitMaterial(color: UIColor(red: 0.94, green: 0.72, blue: 0.18, alpha: 1.0))
        if item.isTarget {
            addBell(to: root, material: material)
        } else {
            addDistractor(to: root, variant: distractorVariant(for: item), material: material)
        }
        return root
    }

    private func addBell(to root: Entity, material: UnlitMaterial) {
        let body = ModelEntity(
            mesh: .generateCone(height: 0.078, radius: 0.048),
            materials: [material]
        )
        body.position.y = 0.005

        let rim = ModelEntity(
            mesh: .generateCylinder(height: 0.012, radius: 0.052),
            materials: [material]
        )
        rim.position.y = -0.036

        let handle = ModelEntity(mesh: .generateSphere(radius: 0.017), materials: [material])
        handle.position.y = 0.049

        let clapper = ModelEntity(mesh: .generateSphere(radius: 0.014), materials: [material])
        clapper.position.y = -0.054

        root.addChild(body)
        root.addChild(rim)
        root.addChild(handle)
        root.addChild(clapper)
    }

    private func addDistractor(to root: Entity, variant: Int, material: UnlitMaterial) {
        switch variant {
        case 0:
            root.addChild(ModelEntity(mesh: .generateSphere(radius: 0.047), materials: [material]))
        case 1:
            root.addChild(ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.088, 0.088, 0.026), cornerRadius: 0.010),
                materials: [material]
            ))
        case 2:
            let cylinder = ModelEntity(
                mesh: .generateCylinder(height: 0.094, radius: 0.031),
                materials: [material]
            )
            cylinder.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            root.addChild(cylinder)
        default:
            let horizontal = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.096, 0.026, 0.026), cornerRadius: 0.008),
                materials: [material]
            )
            let vertical = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.026, 0.096, 0.026), cornerRadius: 0.008),
                materials: [material]
            )
            root.addChild(horizontal)
            root.addChild(vertical)
        }
    }

    private func distractorVariant(for item: AssessmentItem) -> Int {
        let sector = Int(abs(item.angleDegrees) / 15)
        let height = Int((item.verticalOffsetMeters * 100).rounded())
        return abs(sector + height) % 4
    }

    private func applySelectedAppearance(to entity: Entity) {
        entity.scale *= 0.94
        let dimMaterial = UnlitMaterial(
            color: UIColor(red: 0.58, green: 0.45, blue: 0.18, alpha: 1.0)
        )
        apply(material: dimMaterial, to: entity)
    }

    private func apply(material: UnlitMaterial, to entity: Entity) {
        if let model = entity as? ModelEntity {
            model.model?.materials = [material]
        }
        for child in entity.children {
            apply(material: material, to: child)
        }
    }
}

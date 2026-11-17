import RealityKit
import SwiftUI
import UIKit

struct ImmersiveRehabilitationView: View {
    @EnvironmentObject private var rehabilitation: RehabilitationSession
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var isReturningToResults = false
    @State private var cuePulseIsBright = false
    @State private var ringingResource: AudioFileResource?
    @State private var ringingController: AudioPlaybackController?
    @State private var ringingTargetID: UUID?

    private let rootName = "RehabilitationStimuli"
    private let finishAttachmentID = "rehabilitation-finish"
    private let cueAttachmentID = "rehabilitation-cue"
    private let trackingNoticeAttachmentID = "rehabilitation-tracking-notice"

    var body: some View {
        RealityView { content, attachments in
            ringingResource = try? AudioFileResource.load(
                named: "RehabilitationRing.wav",
                configuration: .init(shouldLoop: true)
            )
            let fixedAnchor = AnchorEntity(.head, trackingMode: .once)
            let root = Entity()
            root.name = rootName
            fixedAnchor.addChild(root)
            populate(root)
            content.add(fixedAnchor)

            let controlsAnchor = AnchorEntity(.head, trackingMode: .continuous)
            if let finish = attachments.entity(for: finishAttachmentID) {
                finish.position = SIMD3<Float>(0, -0.34, -0.72)
                controlsAnchor.addChild(finish)
            }
            if let cue = attachments.entity(for: cueAttachmentID) {
                cue.position = SIMD3<Float>(0, 0.27, -0.72)
                controlsAnchor.addChild(cue)
            }
            if let notice = attachments.entity(for: trackingNoticeAttachmentID) {
                notice.position = SIMD3<Float>(0, 0.40, -0.72)
                controlsAnchor.addChild(notice)
            }
            content.add(controlsAnchor)
        } update: { content, _ in
            guard let root = content.entities
                .compactMap({ $0.findEntity(named: rootName) })
                .first else { return }
            let displayedIDs = Set(root.children.map(\.name))
            let requiredIDs = Set(rehabilitation.activeItems.map { $0.id.uuidString })

            // Rebuilding the whole field on every pulse frame makes every
            // symbol disappear and reappear together. Preserve the entities
            // when the trial is unchanged and update only their appearance.
            if displayedIDs != requiredIDs {
                for child in Array(root.children) { child.removeFromParent() }
                populate(root)
            } else {
                updateAppearance(in: root)
            }
            updateRinging(in: root)
        } attachments: {
            Attachment(id: finishAttachmentID) {
                HStack(spacing: 12) {
                    Text(progressText)
                        .font(.callout.monospacedDigit())
                    Button("End Session") { rehabilitation.finish() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .glassBackgroundEffect()
            }

            Attachment(id: cueAttachmentID) {
                if let message = rehabilitation.cueMessage {
                    Label(
                        message,
                        systemImage: rehabilitation.affectedSide == .left
                            ? "arrow.left.circle.fill"
                            : "arrow.right.circle.fill"
                    )
                    .font(rehabilitation.cueLevel == .strong ? .title2.bold() : .headline)
                    .foregroundStyle(.yellow)
                    .padding(14)
                    .glassBackgroundEffect()
                }
            }

            Attachment(id: trackingNoticeAttachmentID) {
                if rehabilitation.isSimulatorDemo {
                    Label(
                        "DEMO MODE · Camera rotation is synthetic head movement",
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                    )
                    .font(.callout.bold())
                    .foregroundStyle(.orange)
                    .padding(12)
                    .glassBackgroundEffect()
                }
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    guard let id = UUID(uuidString: value.entity.name) else { return }
                    _ = rehabilitation.select(itemID: id)
                }
        )
        .task { await rehabilitation.start() }
        .task(id: rehabilitation.cueLevel) {
            guard rehabilitation.cueLevel != .none else {
                cuePulseIsBright = false
                return
            }
            while !Task.isCancelled, rehabilitation.cueLevel != .none {
                cuePulseIsBright.toggle()
                try? await Task.sleep(for: RehabilitationCueProtocol.pulseInterval)
            }
            cuePulseIsBright = false
        }
        .onDisappear { stopRinging() }
        .onChange(of: rehabilitation.phase) { _, phase in
            if phase != .training { stopRinging() }
            if phase == .summary { returnToResults() }
        }
    }

    private func stopRinging() {
        ringingController?.stop()
        ringingController = nil
        ringingTargetID = nil
    }

    private func updateRinging(in root: Entity) {
        guard rehabilitation.phase == .training,
              rehabilitation.pathway == .orientation,
              rehabilitation.cueLevel == .strong,
              let targetID = rehabilitation.cuedItemID,
              let target = root.findEntity(named: targetID.uuidString),
              let resource = ringingResource else {
            stopRinging()
            return
        }
        guard ringingTargetID != targetID else { return }
        stopRinging()
        target.spatialAudio = SpatialAudioComponent(gain: -18)
        ringingController = target.playAudio(resource)
        ringingTargetID = targetID
    }

    private var progressText: String {
        if rehabilitation.pathway == .orientation {
            return "Trial \(min(rehabilitation.trialNumber, rehabilitation.trialCount)) / \(rehabilitation.trialCount)"
        }
        return "Bells \(rehabilitation.targetsFound) / \(rehabilitation.targetCount)"
    }

    private func returnToResults() {
        guard !isReturningToResults else { return }
        isReturningToResults = true
        Task { @MainActor in
            await dismissImmersiveSpace()
            openWindow(id: AssessmentSession.mainWindowID)
        }
    }

    private func populate(_ root: Entity) {
        for item in rehabilitation.activeItems {
            let radians = Float(item.angleDegrees * .pi / 180)
            let elevation = Float(item.elevationDegrees * .pi / 180)
            let radius: Float = 1.0
            let horizontalRadius = cos(elevation) * radius
            let entity = stimulus(for: item)
            entity.position = SIMD3<Float>(
                sin(radians) * horizontalRadius,
                sin(elevation) * radius - 0.08,
                -cos(radians) * horizontalRadius
            )
            entity.orientation = simd_quatf(angle: -radians, axis: SIMD3<Float>(0, 1, 0))
            root.addChild(entity)
        }
        updateAppearance(in: root)
    }

    private func updateAppearance(in root: Entity) {
        let cuedItemID = rehabilitation.cuedItemID

        for item in rehabilitation.activeItems {
            guard let entity = root.children.first(where: { $0.name == item.id.uuidString }) else {
                continue
            }

            let baseScale: Float = rehabilitation.pathway == .orientation ? 0.82 : 0.68
            var displayScale = baseScale

            if item.id == cuedItemID {
                if rehabilitation.cueLevel == .strong {
                    displayScale *= cuePulseIsBright ? 1.32 : 0.88
                } else {
                    displayScale *= cuePulseIsBright ? 1.18 : 0.94
                }
            }

            let isSelected = rehabilitation.selectedItemIDs.contains(item.id)
            if isSelected { displayScale *= 0.82 }
            entity.scale = SIMD3<Float>(repeating: displayScale)

            let material: UnlitMaterial
            if isSelected {
                material = UnlitMaterial(color: UIColor(white: 0.38, alpha: 0.55))
            } else {
                material = UnlitMaterial(color: displayColor(for: item, cuedItemID: cuedItemID))
            }
            apply(material: material, to: entity)
        }
    }

    private func stimulus(for item: RehabilitationItem) -> Entity {
        let root = Entity()
        root.name = item.id.uuidString
        root.components.set(InputTargetComponent())
        root.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.068)]))
        let material = UnlitMaterial(color: displayColor(for: item, cuedItemID: nil))

        if item.isTarget {
            addBell(to: root, material: material)
        } else {
            addDistractor(to: root, variant: item.variant, material: material)
        }
        return root
    }

    private func displayColor(for item: RehabilitationItem, cuedItemID: UUID?) -> UIColor {
        if item.id == cuedItemID, cuePulseIsBright {
            return rehabilitation.cueLevel == .strong
                ? UIColor(red: 1.00, green: 0.98, blue: 0.72, alpha: 1)
                : UIColor(red: 1.00, green: 0.86, blue: 0.24, alpha: 1)
        }
        // Before a timed cue, targets and distractors must have exactly the
        // same luminance and colour. Otherwise the target is disclosed before
        // the user has had an uncued opportunity to search for it.
        return UIColor(red: 0.79, green: 0.60, blue: 0.14, alpha: 1)
    }

    private func addBell(to root: Entity, material: UnlitMaterial) {
        let body = ModelEntity(mesh: .generateCone(height: 0.078, radius: 0.048), materials: [material])
        body.position.y = 0.005
        let rim = ModelEntity(mesh: .generateCylinder(height: 0.012, radius: 0.052), materials: [material])
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
        switch variant % 4 {
        case 0:
            root.addChild(ModelEntity(mesh: .generateSphere(radius: 0.047), materials: [material]))
        case 1:
            root.addChild(ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.088, 0.088, 0.026), cornerRadius: 0.010),
                materials: [material]
            ))
        case 2:
            let cylinder = ModelEntity(mesh: .generateCylinder(height: 0.094, radius: 0.031), materials: [material])
            cylinder.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            root.addChild(cylinder)
        default:
            root.addChild(ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.096, 0.026, 0.026), cornerRadius: 0.008),
                materials: [material]
            ))
            root.addChild(ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.026, 0.096, 0.026), cornerRadius: 0.008),
                materials: [material]
            ))
        }
    }

    private func apply(material: UnlitMaterial, to entity: Entity) {
        if let model = entity as? ModelEntity { model.model?.materials = [material] }
        for child in entity.children { apply(material: material, to: child) }
    }
}

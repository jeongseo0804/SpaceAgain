//
//  Bells_Test_V2Tests.swift
//  Bells-Test-V2Tests
//
//  Created by Interactive 3D Design on 16/8/25.
//

import Foundation
import simd
import Testing
@testable import SpaceAgain

struct SpaceAgainTests {

    @Test func standardizedStimulusCounts() {
        let items = StimulusLayout.makeItems()

        #expect(items.count == 315)
        #expect(items.filter(\.isTarget).count == StimulusLayout.expectedTargetCount)
        #expect(items.filter { !$0.isTarget }.count == StimulusLayout.expectedDistractorCount)
    }

    @Test func everySectorMatchesTheStandardizedColumnCounts() {
        let items = StimulusLayout.makeItems()

        for sector in SpatialSector.allCases {
            let sectorItems = items.filter { $0.sector == sector }
            #expect(sectorItems.count == 45)
            #expect(sectorItems.filter(\.isTarget).count == 5)
            #expect(sectorItems.filter { !$0.isTarget }.count == 40)
        }
    }

    @Test func layoutCoversAFullFrontalHemisphere() {
        let items = StimulusLayout.makeItems()
        let angles = items.map(\.angleDegrees)

        #expect(angles.min()! >= StimulusLayout.horizontalBounds.lowerBound)
        #expect(angles.max()! <= StimulusLayout.horizontalBounds.upperBound)
        #expect(angles.min()! < -85)
        #expect(angles.max()! > 85)
    }

    @Test func hemispaceCountsAreBalancedAroundTheCenterSector() {
        let targets = StimulusLayout.makeItems().filter(\.isTarget)

        #expect(targets.filter { $0.hemispace == .left }.count == 15)
        #expect(targets.filter { $0.hemispace == .center }.count == 5)
        #expect(targets.filter { $0.hemispace == .right }.count == 15)
    }

    @Test func pseudoRandomLayoutIsFixedAcrossAdministrations() {
        func signature(_ item: AssessmentItem) -> String {
            "\(item.symbol)|\(item.isTarget)|\(item.angleDegrees)|\(item.verticalOffsetMeters)"
        }

        let first = StimulusLayout.makeItems().map(signature).sorted()
        let second = StimulusLayout.makeItems().map(signature).sorted()

        #expect(first == second)
    }

    @Test func neighboringSymbolsHaveMinimumAngularSeparation() {
        let items = StimulusLayout.makeItems()

        for firstIndex in items.indices {
            for secondIndex in items.indices where secondIndex > firstIndex {
                let first = items[firstIndex]
                let second = items[secondIndex]
                let firstElevation = asin(Double(first.verticalOffsetMeters / first.radiusMeters))
                let secondElevation = asin(Double(second.verticalOffsetMeters / second.radiusMeters))
                let azimuthDifference = (first.angleDegrees - second.angleDegrees) * .pi / 180
                let cosine = sin(firstElevation) * sin(secondElevation)
                    + cos(firstElevation) * cos(secondElevation) * cos(azimuthDifference)
                let distance = acos(min(1, max(-1, cosine))) * 180 / .pi

                #expect(distance >= StimulusLayout.minimumAngularSeparationDegrees - 0.001)
            }
        }
    }

    @Test func limitedAffectedSideHeadMovementRecommendsOrientation() {
        let result = makeResult(
            leftOmissions: 8,
            rightOmissions: 1,
            leftReach: 20,
            rightReach: 75,
            leftDwell: 1,
            rightDwell: 12,
            hasTracking: true
        )

        let profile = RehabilitationProfileAnalyzer.makeProfile(from: result)

        #expect(profile.affectedSide == .left)
        #expect(profile.recommendedPathway == .orientation)
        #expect(profile.orientationNeed > profile.explorationNeed)
    }

    @Test func persistentOmissionsAfterAdequateHeadExplorationRecommendExploration() {
        let result = makeResult(
            leftOmissions: 8,
            rightOmissions: 1,
            leftReach: 75,
            rightReach: 75,
            leftDwell: 10,
            rightDwell: 10,
            hasTracking: true
        )

        let profile = RehabilitationProfileAnalyzer.makeProfile(from: result)

        #expect(profile.affectedSide == .left)
        #expect(profile.recommendedPathway == .exploration)
        #expect(profile.explorationNeed > profile.orientationNeed)
    }

    @Test func missingHeadTrackingRequiresReview() {
        let result = makeResult(
            leftOmissions: 8,
            rightOmissions: 1,
            leftReach: 0,
            rightReach: 0,
            leftDwell: 0,
            rightDwell: 0,
            hasTracking: false
        )

        let profile = RehabilitationProfileAnalyzer.makeProfile(from: result)

        #expect(profile.recommendedPathway == .clinicianReview)
        #expect(profile.hasReliableHeadTracking == false)
    }

    @Test func simulatorCameraRotationEnablesDemoRoutingWithoutClaimingReliability() {
        let result = makeResult(
            leftOmissions: 8,
            rightOmissions: 1,
            leftReach: 20,
            rightReach: 75,
            leftDwell: 1,
            rightDwell: 12,
            hasTracking: false,
            trackingSource: .simulatorCamera
        )

        let profile = RehabilitationProfileAnalyzer.makeProfile(from: result)

        #expect(profile.recommendedPathway == .orientation)
        #expect(profile.hasUsableTrackingForCurrentRun)
        #expect(profile.isSimulatorDemo)
        #expect(profile.hasReliableHeadTracking == false)
    }

    @Test func rehabilitationCueSchedulePreservesIndependentSearchBeforeEscalation() {
        #expect(RehabilitationCueProtocol.initialCueDelay == 10)
        #expect(RehabilitationCueProtocol.escalationInterval == 3)
        #expect(RehabilitationCueProtocol.strongCueDelay == 13)
    }

    @Test @MainActor func headCalibrationUsesTheSpecifiedToleranceAndHoldDuration() {
        #expect(AssessmentSession.calibrationInnerToleranceDegrees == 10)
        #expect(AssessmentSession.calibrationWarningDegrees == 15)
        #expect(AssessmentSession.calibrationHoldDuration == 5)
        #expect(
            AssessmentSession.trackingUnavailableMessage
                == "Head tracking unavailable. Please remain still while tracking reconnects."
        )
    }

    private func makeResult(
        leftOmissions: Int,
        rightOmissions: Int,
        leftReach: Double,
        rightReach: Double,
        leftDwell: TimeInterval,
        rightDwell: TimeInterval,
        hasTracking: Bool,
        trackingSource: HeadTrackingSource? = nil
    ) -> AssessmentResult {
        let leftDistribution = distribute(leftOmissions)
        let rightDistribution = distribute(rightOmissions)
        let omissions = leftDistribution + [0] + rightDistribution
        let sectors = zip(SpatialSector.allCases, omissions).map { sector, omitted in
            SectorResult(
                sector: sector,
                targetsAvailable: 5,
                targetsCancelled: 5 - omitted,
                omissions: omitted,
                detectionPercentage: Double(5 - omitted) / 5 * 100,
                meanResponseTime: 5
            )
        }
        return AssessmentResult(
            completedAt: Date(),
            durationSeconds: 30,
            targetCount: 35,
            targetsFound: 35 - leftOmissions - rightOmissions,
            falsePositiveCount: 0,
            leftTargetCount: 15,
            rightTargetCount: 15,
            centerTargetCount: 5,
            leftOmissions: leftOmissions,
            rightOmissions: rightOmissions,
            centerOmissions: 0,
            meanLeftResponseTime: 8,
            meanRightResponseTime: 4,
            maximumLeftExplorationDegrees: leftReach,
            maximumRightExplorationDegrees: rightReach,
            firstScanningDirection: .right,
            timeBeforeFirstLeftExploration: 8,
            timeBeforeFirstRightExploration: 1,
            leftExplorationTime: leftDwell,
            centerExplorationTime: 5,
            rightExplorationTime: rightDwell,
            angularDwellSeconds: hasTracking ? [0: 1] : [:],
            headTrackingWasReliable: hasTracking,
            headTrackingSource: trackingSource,
            sectorResults: sectors,
            detections: []
        )
    }

    private func distribute(_ omissions: Int) -> [Int] {
        var remaining = omissions
        return (0 ..< 3).map { _ in
            let value = min(5, remaining)
            remaining -= value
            return value
        }
    }

}

@MainActor
struct IdleCalibrationTests {
    @Test func briefTrackingGapsPauseInsteadOfRestartingTheHold() {
        let session = AssessmentSession()
        session.prepareAssessment()
        #expect(session.beginCalibration())
        session.processTrackingSample(matrix_identity_float4x4, at: 0)
        session.processTrackingSample(matrix_identity_float4x4, at: 4)
        session.processTrackingSample(nil, at: 4.1)
        session.processTrackingSample(matrix_identity_float4x4, at: 4.2)
        session.processTrackingSample(matrix_identity_float4x4, at: 5)
        #expect(!session.canBeginAssessment)
        session.processTrackingSample(matrix_identity_float4x4, at: 5.2)
        #expect(session.canBeginAssessment)
    }

    @Test func returningToANewAssessmentRequiresANewBaseline() {
        let session = AssessmentSession()
        session.prepareAssessment()
        #expect(session.beginCalibration())
        session.processTrackingSample(matrix_identity_float4x4, at: 0)
        session.processTrackingSample(matrix_identity_float4x4, at: 5)
        #expect(session.canBeginAssessment)
        session.reset()
        session.prepareAssessment()
        #expect(session.beginCalibration())
        #expect(!session.canBeginAssessment)
        #expect(session.initialDeviceTransform == nil)
    }

    @Test func fiveSecondsOfStillnessEnablesAndStartsAssessment() {
        let session = AssessmentSession()
        session.prepareAssessment()
        #expect(session.beginCalibration())
        session.processTrackingSample(matrix_identity_float4x4, at: 10)
        session.processTrackingSample(matrix_identity_float4x4, at: 14.9)
        #expect(!session.canBeginAssessment)
        session.processTrackingSample(matrix_identity_float4x4, at: 15)
        #expect(session.canBeginAssessment)
        session.beginAssessmentAfterCalibration()
        #expect(session.phase == .assessing)
    }

    @Test func trackingDropoutPreservesConfirmedBaselineAndRecoversStartButton() {
        let session = AssessmentSession()
        session.prepareAssessment()
        #expect(session.beginCalibration())
        session.processTrackingSample(matrix_identity_float4x4, at: 10)
        session.processTrackingSample(matrix_identity_float4x4, at: 15)
        session.processTrackingSample(nil, at: 15.1)
        #expect(!session.canBeginAssessment)
        #expect(session.calibrationStatus == .confirmed)
        let moved = simd_float4x4(simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0)))
        session.processTrackingSample(moved, at: 15.2)
        #expect(session.canBeginAssessment)
        #expect(session.initialDeviceTransform == matrix_identity_float4x4)
        session.beginAssessmentAfterCalibration()
        #expect(session.phase == .assessing)
    }

    @Test func trackingLossBeforeConfirmationRequiresANewFiveSecondHold() {
        let session = AssessmentSession()
        session.prepareAssessment()
        #expect(session.beginCalibration())
        session.processTrackingSample(matrix_identity_float4x4, at: 0)
        session.processTrackingSample(nil, at: 4)
        session.processTrackingSample(matrix_identity_float4x4, at: 5)
        session.processTrackingSample(matrix_identity_float4x4, at: 9.9)
        #expect(!session.canBeginAssessment)
        session.processTrackingSample(matrix_identity_float4x4, at: 10)
        #expect(session.canBeginAssessment)
    }

    @Test func capturesTheStablePoseAfterFiveSeconds() {
        let session = AssessmentSession()
        var pose = simd_float4x4(simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(0, 1, 0)))
        pose.columns.3 = SIMD4<Float>(0.2, 1.6, -0.4, 1)
        session.processCalibrationTransform(pose, at: 10)
        session.processCalibrationTransform(pose, at: 14.9)
        #expect(session.initialDeviceTransform == nil)
        session.processCalibrationTransform(pose, at: 15.1)
        #expect(session.calibrationStatus == .confirmed)
        #expect(session.initialDeviceTransform == pose)
        session.processCalibrationTransform(matrix_identity_float4x4, at: 20)
        #expect(session.initialDeviceTransform == pose)
    }

    @Test func movementRestartsTheStillnessTimer() {
        let session = AssessmentSession()
        session.processCalibrationTransform(matrix_identity_float4x4, at: 0)
        let moved = simd_float4x4(simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0)))
        session.processCalibrationTransform(moved, at: 4)
        session.processCalibrationTransform(moved, at: 5.1)
        #expect(session.calibrationStatus == .holdingPosition)
        #expect(session.initialDeviceTransform == nil)
        session.processCalibrationTransform(moved, at: 9.1)
        #expect(session.initialDeviceTransform == moved)
    }
}

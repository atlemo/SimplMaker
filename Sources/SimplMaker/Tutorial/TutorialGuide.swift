// The guide of a document window: which step the tutorial is on, and whether it's showing.
//
// The step is never counted. It's the first one the part doesn't satisfy yet (`current`), so
// undoing work brings the guide back to the step that was undone, and a user who runs ahead is not
// told to do what's done. Only the "read" steps (a welcome, a tour of the panels) need remembering.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Observation

@MainActor
@Observable
final class TutorialGuide {
    /// The card is showing.
    private(set) var isActive: Bool
    /// "Read" steps the user has moved past.
    private(set) var acknowledged: Set<String> = []
    /// The last step's button was pressed.
    private(set) var isFinished = false
    /// A "Do it for me" is running.
    private(set) var isAssisting = false
    /// What pulses in the window right now (see `View.tutorialSpot`); the card keeps it up to date.
    var spotlight: Set<String> = []
    /// The card shows only its title and next move.
    var isCollapsed = false

    init(active: Bool = false) { isActive = active }

    // MARK: running

    func start() {
        isActive = true
        isCollapsed = false
    }

    /// Hides the card, keeping the progress (Help ▸ Tutorial brings it back).
    func stop() {
        isActive = false
        spotlight = []
    }

    /// The last step's button: the tutorial is done, and the welcome window stops offering it first.
    func finish() {
        isFinished = true
        isActive = false
        spotlight = []
        UserDefaults.standard.set(true, forKey: Preferences.tutorialCompleted)
    }

    /// Some progress was made and the tutorial isn't finished: Help ▸ Tutorial resumes it.
    var canResume: Bool { !isActive && !isFinished && !acknowledged.isEmpty }

    // MARK: steps

    var steps: [TutorialStep] { TutorialScript.steps }

    func isDone(_ step: TutorialStep, in model: DocumentModel) -> Bool {
        switch step.kind {
        case .read: return acknowledged.contains(step.id)
        case .task(let done): return done(model)
        }
    }

    /// The step to show: the first one that isn't done.
    func current(in model: DocumentModel) -> TutorialStep? {
        steps.first { !isDone($0, in: model) }
    }

    /// How many steps come before this one, and how many there are in all.
    func position(of step: TutorialStep) -> (index: Int, count: Int) {
        (steps.firstIndex { $0.id == step.id } ?? 0, steps.count)
    }

    /// The button of a "read" step.
    func acknowledge(_ step: TutorialStep) {
        acknowledged.insert(step.id)
        if step.id == TutorialScript.done.id { finish() }
    }

    /// Does the step for the user, with the parameters it needs in place first.
    func assist(_ step: TutorialStep, in model: DocumentModel) async {
        guard !isAssisting, let assist = step.assist else { return }
        isAssisting = true
        defer { isAssisting = false }
        TutorialActions.seedParameters(model)
        await assist(model)
    }
}

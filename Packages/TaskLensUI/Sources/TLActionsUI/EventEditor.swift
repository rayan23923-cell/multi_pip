import EventKit
import EventKitUI
import SwiftUI

/// The system's "New Event" editor, filled in from an `EventDraft`.
///
/// Since iOS 17 this editor runs outside the app, so TaskLens needs no
/// calendar permission and never reads the user's calendars. Nothing is
/// saved unless the user taps Add.
struct EventEditor: UIViewControllerRepresentable {
    let draft: EventDraft
    let onFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: @MainActor () -> Void

        init(onFinish: @escaping @MainActor () -> Void) {
            self.onFinish = onFinish
        }

        nonisolated func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            MainActor.assumeIsolated { onFinish() }
        }
    }
}

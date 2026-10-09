import Foundation
import UserNotifications

/// Small dispatcher for notification categories owned by macOS-only features
/// (meeting detection, calendar reminders, …). `TaskReminderScheduler` owns the
/// single system delegate (it is also compiled for iOS), and exposes one
/// `additionalCategories` set and one `externalResponseHandler`; this router
/// lets several features share them, each registering its categories with a
/// handler.
@MainActor
final class NotificationRouter {

    static let shared = NotificationRouter()

    typealias Handler = @MainActor (_ categoryId: String, _ actionId: String, _ userInfo: [String: String]) -> Void

    private var handlers: [String: Handler] = [:]
    private var categories: Set<UNNotificationCategory> = []

    /// Registers `categories` and routes responses for them to `handler`.
    /// Call before `install(on:)`.
    func register(categories: Set<UNNotificationCategory>, handler: @escaping Handler) {
        for category in categories {
            handlers[category.identifier] = handler
        }
        self.categories.formUnion(categories)
    }

    /// Hands the combined categories and the dispatching handler to the
    /// scheduler. Call before `registerCategory()`.
    func install(on scheduler: TaskReminderScheduler) {
        scheduler.additionalCategories = categories
        scheduler.externalResponseHandler = { categoryId, actionId, userInfo in
            NotificationRouter.shared.route(categoryId: categoryId, actionId: actionId, userInfo: userInfo)
        }
    }

    /// Dispatches a response to the handler registered for its category.
    /// Returns false when no handler is registered.
    @discardableResult
    func route(categoryId: String, actionId: String, userInfo: [String: String]) -> Bool {
        guard let handler = handlers[categoryId] else { return false }
        handler(categoryId, actionId, userInfo)
        return true
    }
}

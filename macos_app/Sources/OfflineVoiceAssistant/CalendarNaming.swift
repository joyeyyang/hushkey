import EventKit
import Foundation

/// Names a recording after the calendar event it belongs to.
///
/// Only the title is read, never the notes or attendees: the point is that a
/// recording should not be called "會議 2026-10-20 1430" when the calendar
/// already knows it is "Q3 上線會議". Permission is optional — when it is not
/// granted every call returns nil and the caller falls back to the summary's
/// first sentence.
enum CalendarNaming {
    private static let store = EKEventStore()

    /// A meeting that already started wins; if none is running, the one starting
    /// within the next ten minutes does. That covers pressing the hotkey a
    /// little early, which is what people actually do.
    private static let lookahead: TimeInterval = 10 * 60
    private static let maxTitleLength = 60

    static var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    static var needsPermission: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    /// Asks once per launch at most; a denied prompt must not reappear every time
    /// a recording starts.
    static func requestAccessIfNeeded(_ completion: @escaping (Bool) -> Void) {
        guard needsPermission else {
            completion(isAuthorized)
            return
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// Title of the event this recording belongs to, or nil.
    static func eventTitle(at date: Date = Date()) -> String? {
        guard isAuthorized else { return nil }
        let windowStart = date.addingTimeInterval(-60)
        let windowEnd = date.addingTimeInterval(lookahead)
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && !$0.title.isEmpty }
        guard !events.isEmpty else { return nil }

        let running = events.filter { $0.startDate <= date && $0.endDate >= date }
        // In a back-to-back calendar two events overlap the same minute; the one
        // that started most recently is the meeting this recording is about.
        let chosen = running.max(by: { $0.startDate < $1.startDate })
            ?? events.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) })

        guard let title = chosen?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return String(title.prefix(maxTitleLength))
    }

    /// The event that just ended, used when a recording is stopped a few minutes
    /// past the meeting. Falls back to nil rather than naming the recording after
    /// something that has nothing to do with it.
    static func recentlyEndedTitle(at date: Date = Date(), within: TimeInterval = 15 * 60) -> String? {
        guard isAuthorized else { return nil }
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-within),
            end: date,
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && !$0.title.isEmpty }
            .max(by: { $0.endDate < $1.endDate })?
            .title
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

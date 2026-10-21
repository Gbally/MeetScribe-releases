// Calendar (meeting titles + attendees) and Reminders (export to-dos), via macOS EventKit.
// Outlook / Exchange events show up here when the work account is added to the Calendar app
// (System Settings → Internet Accounts → Microsoft Exchange).

import EventKit
import Foundation

struct Attendee: Codable, Hashable {
    var name: String
    var email: String
}

struct CalendarEvent: Codable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var organizer: String
    var attendees: [Attendee]
    var isOnlineMeeting: Bool

    var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    // .authorized has the same raw value as macOS 14's .fullAccess.
    var eventsAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .authorized }
    var eventsUndecided: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    func requestEvents() async -> Bool {
        await withCheckedContinuation { c in store.requestAccess(to: .event) { ok, _ in c.resume(returning: ok) } }
    }

    func requestReminders() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .authorized { return true }
        return await withCheckedContinuation { c in store.requestAccess(to: .reminder) { ok, _ in c.resume(returning: ok) } }
    }

    /// The meeting happening now (or starting within 10 minutes), preferring real meetings
    /// (with attendees or a Teams/Zoom link) over personal blocks.
    func currentMeeting(at now: Date = Date()) -> CalendarEvent? {
        guard eventsAllowed else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600),
                                                 end: now.addingTimeInterval(600), calendars: nil)
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.endDate > now && $0.startDate <= now.addingTimeInterval(600)
                && $0.status != .canceled && $0.endDate.timeIntervalSince($0.startDate) < 6 * 3600
        }
        let best = candidates.max { score($0, now) < score($1, now) }
        return best.map(Self.convert)
    }

    private func score(_ e: EKEvent, _ now: Date) -> Double {
        var s = 0.0
        if Self.isOnline(e) { s += 3 }
        if (e.attendees?.count ?? 0) > 1 { s += 2 }
        s -= abs(e.startDate.timeIntervalSince(now)) / 3600 // closest start wins ties
        return s
    }

    private static func isOnline(_ e: EKEvent) -> Bool {
        let text = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["teams.microsoft.com", "zoom.us", "webex.com", "meet.google.com"].contains { text.contains($0) }
    }

    private static func convert(_ e: EKEvent) -> CalendarEvent {
        func attendee(_ p: EKParticipant) -> Attendee {
            let email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            let name = p.name ?? email.components(separatedBy: "@").first ?? email
            return Attendee(name: name, email: email.contains("@") ? email : "")
        }
        let people = (e.attendees ?? []).filter {
            $0.participantType != .room && $0.participantType != .resource && !$0.isCurrentUser
        }
        return CalendarEvent(title: e.title ?? "Meeting", start: e.startDate, end: e.endDate,
                             organizer: e.organizer?.name ?? "", attendees: people.map(attendee),
                             isOnlineMeeting: isOnline(e))
    }

    /// Adds to-dos to the default Reminders list. Returns how many were added.
    func addReminders(_ items: [ActionItem], meetingTitle: String) async -> Int? {
        guard await requestReminders(), let list = store.defaultCalendarForNewReminders() else { return nil }
        var added = 0
        for item in items {
            let r = EKReminder(eventStore: store)
            r.calendar = list
            r.title = item.task
            r.notes = ["From meeting: \(meetingTitle)", item.due.isEmpty ? nil : "Due: \(item.due)"]
                .compactMap { $0 }.joined(separator: "\n")
            if (try? store.save(r, commit: false)) != nil { added += 1 }
        }
        try? store.commit()
        return added
    }
}

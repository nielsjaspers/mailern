import Foundation

enum DemoData {
    static func conversations(now: Date = .now) -> [Conversation] {
        func thread(_ account: String, _ sender: String, _ address: String, _ subject: String, _ body: String,
                    minutes: Double, status: Workflow = .inbox, unread: Bool = true, pinned: Bool = false) -> Conversation {
            Conversation(accountID: account, subject: subject, workflow: status, unread: unread, pinned: pinned,
                         snoozedUntil: status == .snoozed ? now.addingTimeInterval(3600) : nil,
                         messages: [MailMessage(sender: sender, address: address, to: [MailAccount.demo.first(where: { $0.id == account })!.address],
                                                date: now.addingTimeInterval(-minutes * 60), body: body)])
        }
        var project = thread("university", "Dr. Jordan Lee", "jordan@college.example.com", "Course project feedback",
                             "Hi Morgan,\n\nI read your project outline. The scope is much clearer now. Before we can schedule the presentation, could you send me a short explanation of which reference materials you plan to use?\n\nA paragraph and a rough timeline are enough. Please send these before Friday.\n\nBest,\nJordan", minutes: 12, pinned: true)
        project.messages[0].cc = ["coordinator@college.example.com"]
        var dinner = thread("icloud", "Casey Rivera", "casey@example.com", "Dinner on Saturday?",
                            "Hey! Are you free on Saturday? I was thinking we could cook at my place.\n\nCasey", minutes: 280, unread: false)
        dinner.messages.append(MailMessage(sender: "Morgan", address: MailAccount.demo[0].address, to: ["casey@example.com"], date: now.addingTimeInterval(-7200), body: "Sounds good. What time works for you?", outgoing: true))
        dinner.messages.append(MailMessage(sender: "Casey Rivera", address: "casey@example.com", to: [MailAccount.demo[0].address], date: now.addingTimeInterval(-1800), body: "Around 7? Bring something to drink. I'll take care of dinner.\n\nAlso, Jamie is joining us!"))
        return [project,
                thread("gmail", "Sample Weekly", "newsletter@example.com", "A little less, but better",
                       "SAMPLE WEEKLY\nIssue 318\n\nThis week: tools that leave room for thought.\n\nWhen every app asks for your attention, choosing what to leave out becomes a design decision. We look at three small studios building useful things with restraint.\n\nWorth reading\n• Designing for a slower internet\n• The case for keeping a notebook\n• A library of everyday objects\n\nRead more at https://example.com\n\nHave a good weekend,\nThe editorial team", minutes: 35),
                dinner,
                thread("university", "Course coordinator", "course@college.example.com", "Project presentations · Tuesday 10:00",
                       "Hi everyone,\n\nLet's meet for the course presentations.\n\nTuesday, 10:00–11:00\nClassroom 101\n\nPlease bring your slides and one question for discussion.\n\nAgenda\n1. Five-minute presentations\n2. Group discussion\n3. Next steps\n\nSee you there!", minutes: 70),
                thread("icloud", "Example Parcel Service", "tracking@parcel.example.com", "Your parcel arrives tomorrow",
                       "Hi Morgan,\n\nYour parcel is on its way.\n\nExpected delivery\nTomorrow, between 12:30 and 15:00\n\nNot at home? You can choose a different delivery moment on our website.\n\nTrack your parcel: https://example.com/parcel\n\nExample Parcel Service", minutes: 110, unread: false),
                thread("proton", "Avery", "avery@example.com", "Cabin weekend options",
                       "I've found two places for the weekend in December. Both have a fireplace and are close to the forest.\n\nNo rush. Take a look when you have time next week and we can book something together.\n\nAvery", minutes: 190),
                thread("gmail", "Example Workshop", "hello@workshop.example.com", "Tickets go on sale next week",
                       "Thanks for your interest in the typography workshop. Booking opens next Monday at 09:00.\n\nThe workshop runs from 13:00 to 17:00. All materials are included.\n\nSee you soon,\nExample Workshop", minutes: 400, status: .snoozed, unread: false),
                thread("icloud", "Jamie Chen", "jamie@example.com", "The photos from our trip",
                       "Here are the photos! I finally got around to sorting them.\n\nThanks again for a great weekend. Let's do it again soon.\n\nJamie", minutes: 1440, status: .settled, unread: false),
                thread("proton", "Bookshop", "orders@bookshop.example", "Your order is confirmed",
                       "Thank you for your order.\n\n1 × An Example Book\n\nWe'll let you know when your book ships.\n\nOrder #10428", minutes: 2200, status: .settled, unread: false)]
    }
}

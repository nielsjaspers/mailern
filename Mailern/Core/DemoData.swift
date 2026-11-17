import Foundation

enum DemoData {
    static func conversations(now: Date = .now) -> [Conversation] {
        func thread(_ account: String, _ sender: String, _ address: String, _ subject: String, _ body: String,
                    minutes: Double, status: Workflow = .inbox, unread: Bool = true, pinned: Bool = false) -> Conversation {
            Conversation(accountID: account, subject: subject, workflow: status, unread: unread, pinned: pinned,
                         snoozedUntil: status == .snoozed ? now.addingTimeInterval(3600) : nil,
                         messages: [MailMessage(sender: sender, address: address, to: [MailAccount.demo.first(where: { $0.id == account })!.address],
                                                date: now.addingTimeInterval(-minutes * 60), body: body,
                                                messageID: MailMessage.newMessageID(from: address))])
        }
        var project = thread("university", "Dr. Jordan Lee", "jordan@college.example.com", "Course project feedback",
                             "Hi Morgan,\n\nI read your project outline. The scope is much clearer now. Before we can schedule the presentation, could you send me a short explanation of which reference materials you plan to use?\n\nA paragraph and a rough timeline are enough. Please send these before Friday.\n\nBest,\nJordan", minutes: 12, pinned: true)
        project.messages[0].cc = ["coordinator@college.example.com"]
        var dinner = thread("icloud", "Casey Rivera", "casey@example.com", "Dinner on Saturday?",
                            "Hey! Are you free on Saturday? I was thinking we could cook at my place.\n\nCasey", minutes: 280, unread: false)
        var answer = MailMessage(sender: "Morgan", address: MailAccount.demo[0].address, to: ["casey@example.com"], date: now.addingTimeInterval(-7200),
                                 body: "Sounds good. What time works for you?", outgoing: true, messageID: MailMessage.newMessageID(from: MailAccount.demo[0].address))
        answer.answer(dinner.messages[0])
        var followUp = MailMessage(sender: "Casey Rivera", address: "casey@example.com", to: [MailAccount.demo[0].address], date: now.addingTimeInterval(-1800),
                                   body: "Around 7? Bring something to drink. I'll take care of dinner.\n\nAlso, Jamie is joining us!",
                                   messageID: MailMessage.newMessageID(from: "casey@example.com"))
        followUp.answer(answer)
        dinner.messages += [answer, followUp]
        var weekly = thread("gmail", "Sample Weekly", "newsletter@example.com", "A little less, but better",
                       "SAMPLE WEEKLY\nIssue 318\n\nThis week: tools that leave room for thought.\n\nWhen every app asks for your attention, choosing what to leave out becomes a design decision. We look at three small studios building useful things with restraint.\n\nWorth reading\n• Designing for a slower internet\n• The case for keeping a notebook\n• A library of everyday objects\n\nRead more at https://example.com\n\nHave a good weekend,\nThe editorial team", minutes: 35)
        weekly.messages[0].html = weeklyHTML
        var workshop = thread("gmail", "Example Workshop", "hello@workshop.example.com", "Tickets go on sale next week",
                              "Thanks for your interest in the typography workshop. Booking opens next Monday at 09:00.\n\nThe workshop runs from 13:00 to 17:00. All materials are included.\n\nSee you soon,\nExample Workshop", minutes: 400, status: .snoozed, unread: false)
        workshop.messages[0].html = workshopHTML
        return [project,
                weekly,
                dinner,
                thread("university", "Course coordinator", "course@college.example.com", "Project presentations · Tuesday 10:00",
                       "Hi everyone,\n\nLet's meet for the course presentations.\n\nTuesday, 10:00–11:00\nClassroom 101\n\nPlease bring your slides and one question for discussion.\n\nAgenda\n1. Five-minute presentations\n2. Group discussion\n3. Next steps\n\nQuestions? Write to course@college.example.com.\n\nSee you there!", minutes: 70),
                thread("icloud", "Example Parcel Service", "tracking@parcel.example.com", "Your parcel arrives tomorrow",
                       "Hi Morgan,\n\nYour parcel is on its way.\n\nExpected delivery\nTomorrow, between 12:30 and 15:00\n\nNot at home? You can choose a different delivery moment on our website.\n\nTrack your parcel: https://example.com/parcel\n\nExample Parcel Service", minutes: 110, unread: false),
                thread("proton", "Avery", "avery@example.com", "Cabin weekend options",
                       "I've found two places for the weekend in December. Both have a fireplace and are close to the forest.\n\nNo rush. Take a look when you have time next week and we can book something together.\n\nAvery", minutes: 190),
                workshop,
                thread("icloud", "Jamie Chen", "jamie@example.com", "The photos from our trip",
                       "Here are the photos! I finally got around to sorting them.\n\nThanks again for a great weekend. Let's do it again soon.\n\nJamie", minutes: 1440, status: .settled, unread: false),
                thread("proton", "Bookshop", "orders@bookshop.example", "Your order is confirmed",
                       "Thank you for your order.\n\n1 × An Example Book\n\nWe'll let you know when your book ships.\n\nOrder #10428", minutes: 2200, status: .settled, unread: false)]
    }

    /// A newsletter written for light backgrounds. Its remote tracking pixel stays blocked until Load images.
    private static let weeklyHTML = """
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="background:#f4efe6;color:#2b2620;font-family:Georgia,serif">
        <tr><td style="padding:24px 24px 8px;font:600 13px -apple-system,sans-serif;letter-spacing:2px;color:#8a5a2b">SAMPLE WEEKLY · ISSUE 318</td></tr>
        <tr><td style="padding:0 24px"><img src="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 552 240'><rect width='552' height='240' fill='%23e3d8c6'/><rect x='60' y='150' width='432' height='14' rx='4' fill='%238a5a2b'/><rect x='200' y='70' width='150' height='80' rx='6' fill='%23f4efe6'/><circle cx='430' cy='95' r='34' fill='%23c9a46b'/></svg>" width="552" height="240" alt="Cover: a quiet studio desk" style="display:block"></td></tr>
        <tr><td style="padding:16px 24px">
        <h1 style="font-size:26px;line-height:1.2;margin:0 0 12px">A little less, but better</h1>
        <p style="font-size:17px;line-height:1.5">When every app asks for your attention, choosing what to leave out becomes a design decision. We look at three small studios building useful things with restraint.</p>
        <h2 style="font:600 15px -apple-system,sans-serif;margin:20px 0 8px">Worth reading</h2>
        <ul style="font-size:17px;line-height:1.6;padding-left:20px">
        <li><a href="https://example.com/slower-internet" style="color:#8a5a2b">Designing for a slower internet</a></li>
        <li><a href="https://example.com/notebook" target="_blank" style="color:#8a5a2b">The case for keeping a notebook</a></li>
        <li><a href="https://example.com/objects" style="color:#8a5a2b">A library of everyday objects</a></li>
        </ul>
        <p style="font-size:15px;line-height:1.5">Have a tip for next week? Write to <a href="mailto:editors@example.com?subject=Tip%20for%20Sample%20Weekly" style="color:#8a5a2b">the editors</a>.</p>
        <p style="font-size:15px">Have a good weekend,<br>The editorial team</p>
        </td></tr>
        </table>
        <img src="https://example.com/sample-weekly/open.gif" width="1" height="1" alt="">
        """
    /// A message that styles itself for dark mode.
    private static let workshopHTML = """
        <style>
        .card { border-radius: 14px; padding: 20px; background: #eef3ff; color: #1b2440; font-family: -apple-system, sans-serif; }
        .time { font-size: 28px; font-weight: 700; margin: 4px 0 12px; }
        a.button { display: inline-block; padding: 10px 18px; border-radius: 999px; background: #3355dd; color: #fff; text-decoration: none; }
        @media (prefers-color-scheme: dark) {
          .card { background: #1c2340; color: #e6ebff; }
          a.button { background: #8aa2ff; color: #0d1330; }
        }
        </style>
        <div class="card">
        <p>Thanks for your interest in the typography workshop.</p>
        <div>Booking opens</div>
        <div class="time">Monday, 09:00</div>
        <p>The workshop runs from 13:00 to 17:00. All materials are included.</p>
        <p><a class="button" href="https://example.com/workshop">View the programme</a></p>
        <p>See you soon,<br>Example Workshop</p>
        </div>
        """
}

import Foundation

enum BenchmarkMailbox: Int, CaseIterable, Identifiable {
    case tenThousand = 10_000
    case twentyThousand = 20_000

    var id: Int { rawValue }
    var title: String { "\(rawValue.formatted()) conversations" }

    func makeMail(now: Date = .now) -> MailData {
        let accounts = MailAccount.demo
        let topics = ["Project update", "Weekly report", "Order confirmation", "Workshop notes", "Meeting summary"]
        let paragraphs = [
            "The latest draft includes the changes from our meeting. The schedule still leaves a week for feedback and a separate review with the people who will use it.",
            "Please check the dates and the handover notes. If something is missing, reply with the section name and a short description so we can update the shared copy.",
            "We will review the outstanding questions at the next check-in. I will circulate the final version after the review and keep the earlier versions in the archive.",
            "Your order is packed. It will leave the warehouse this afternoon. The pickup notice will have the locker number.",
            "The main hall opens at nine. We have two tables near the entrance for registration and a quieter room upstairs for the workshop.",
            "Thanks for sending this over. The total matches our estimate, and the revised delivery date works for us."
        ]
        let conversations = (1...rawValue).map { number in
            let account = accounts[(number / 5) % accounts.count]
            let subject = "\(topics[number % topics.count]) · Sample \(number)"
            let workflow: Workflow = number.isMultiple(of: 7) ? .settled : .inbox
            let latest = now.addingTimeInterval(Double(-number * 900))
            let messageCount = number.isMultiple(of: 100) ? 16 :
                number.isMultiple(of: 10) ? 6 : number.isMultiple(of: 3) ? 3 : 1
            let senderNumber = (number * 17) % 800
            let sender = "Sample Sender \(senderNumber)"
            let address = "sender-\(senderNumber)@example.com"
            var messages: [MailMessage] = []
            for index in 0..<messageCount {
                let intro = "Here's update \(index + 1) for sample \(number)."
                let count = 1 + (number + index * 3) % 4
                let start = (number + index) % paragraphs.count
                var lines = [intro] + (0..<count).map { paragraphs[(start + $0) % paragraphs.count] }
                if number == 1_471 && index == 0 { lines.append("The handoff code is larchdelta.") }
                let body = lines.joined(separator: "\n\n")
                var message = MailMessage(sender: sender, address: address, to: [account.address],
                                          date: latest.addingTimeInterval(Double((index - messageCount + 1) * 120)),
                                          body: body, subject: index == 0 ? subject : "Re: \(subject)")
                if (number / 3 + index).isMultiple(of: 4) {
                    let html = lines.map { "<p>\($0)</p>" }.joined()
                    message.html = "<article style='max-width:650px;font:16px system-ui'><h1>\(subject)</h1>\(html)</article>"
                }
                if let previous = messages.last { message.answer(previous) }
                messages.append(message)
            }
            return Conversation(accountID: account.id, subject: subject, workflow: workflow,
                                unread: workflow == .inbox && !number.isMultiple(of: 3), messages: messages)
        }
        return MailData(conversations: conversations)
    }
}

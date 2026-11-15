import SwiftUI
import QuickLook

struct AttachmentList: View {
    let attachments: [MailAttachment]
    var remove: ((UUID) -> Void)?
    @State private var preview: PreviewFile?
    @State private var error: String?
    var body: some View {
        VStack(spacing: 8) {
            ForEach(attachments) { file in
                HStack {
                    Button {
                        do { preview = try PreviewFile(file) }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Preview \(file.name)")
                    if let remove {
                        Button("Remove \(file.name)", systemImage: "xmark.circle.fill") { remove(file.id) }
                            .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    }
                }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .quickLookPreview(Binding(get: { preview?.url }, set: { if $0 == nil { preview = nil } }))
        .alert("Attachment", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private final class PreviewFile {
    let id = UUID()
    let url: URL
    private let directory: URL
    init(_ file: MailAttachment) throws {
        directory = URL.temporaryDirectory.appending(path: "mailern-preview-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = (file.name as NSString).lastPathComponent
        url = directory.appending(path: name.isEmpty || name == "." || name == ".." ? "Attachment" : name)
        try file.data.write(to: url, options: .atomic)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

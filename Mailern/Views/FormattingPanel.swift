import SwiftUI

struct FormattingPanel: View {
    let state: RichTextState
    @State private var color = Color.primary
    private let fonts = [("Default Font", ""), ("Helvetica", "Helvetica"), ("Georgia", "Georgia"), ("Menlo", "Menlo"), ("Times New Roman", "TimesNewRomanPSMT")]
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Format").font(.title2.bold())
                Spacer()
                Button("Close formatting", systemImage: "xmark") { state.showFormat(false) }
                    .labelStyle(.iconOnly).padding(10).background(.quaternary, in: Circle())
            }
            HStack(spacing: 0) {
                preset("Title", size: 28, weight: .bold)
                preset("Subtitle", size: 22, weight: .semibold)
                preset("Body", size: 17)
                preset("Caption", size: 13)
            }.background(.quaternary, in: Capsule())
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    style("Bold", icon: "bold", active: state.font.fontDescriptor.symbolicTraits.contains(.traitBold)) { state.toggleTrait(.traitBold) }
                    style("Italic", icon: "italic", active: state.font.fontDescriptor.symbolicTraits.contains(.traitItalic)) { state.toggleTrait(.traitItalic) }
                    style("Underline", icon: "underline", active: (state.attributes[.underlineStyle] as? Int ?? 0) != 0) { state.toggle(.underlineStyle) }
                    style("Strikethrough", icon: "strikethrough", active: (state.attributes[.strikethroughStyle] as? Int ?? 0) != 0) { state.toggle(.strikethroughStyle) }
                }.background(.quaternary, in: Capsule())
                ColorPicker("Text color", selection: $color, supportsOpacity: false).labelsHidden()
                    .onChange(of: color) { _, value in state.attribute(.foregroundColor, UIColor(value)) }
            }
            HStack(spacing: 12) {
                Menu {
                    ForEach(fonts, id: \.0) { name, value in
                        Button(name) { state.setFont(value.isEmpty ? nil : value, size: state.font.pointSize) }
                    }
                } label: { HStack { Text("Font"); Image(systemName: "chevron.up.chevron.down") }.frame(maxWidth: .infinity) }
                .padding(10).background(.quaternary, in: Capsule())
                HStack {
                    Button("Smaller text", systemImage: "minus") { state.setFont(state.font.fontName, size: state.font.pointSize - 1) }
                    Text("\(Int(state.font.pointSize))").monospacedDigit().frame(minWidth: 30)
                    Button("Larger text", systemImage: "plus") { state.setFont(state.font.fontName, size: state.font.pointSize + 1) }
                }.labelStyle(.iconOnly).padding(10).background(.quaternary, in: Capsule())
            }
            HStack(spacing: 12) {
                Menu {
                    Button("Bulleted list", systemImage: "list.bullet") { state.list(numbered: false) }
                    Button("Numbered list", systemImage: "list.number") { state.list(numbered: true) }
                    Button("Remove list") { state.paragraph { $0.textLists = [] } }
                } label: { Image(systemName: "list.bullet").frame(maxWidth: .infinity) }.accessibilityLabel("Lists")
                Menu {
                    Button("Align left", systemImage: "text.alignleft") { state.paragraph { $0.alignment = .left } }
                    Button("Align center", systemImage: "text.aligncenter") { state.paragraph { $0.alignment = .center } }
                    Button("Align right", systemImage: "text.alignright") { state.paragraph { $0.alignment = .right } }
                } label: { Image(systemName: "text.alignleft").frame(maxWidth: .infinity) }.accessibilityLabel("Alignment")
                Button("Decrease indent", systemImage: "decrease.indent") {
                    state.paragraph { $0.headIndent = max(0, $0.headIndent - 20); $0.firstLineHeadIndent = $0.headIndent }
                }.frame(maxWidth: .infinity)
                Button("Increase indent", systemImage: "increase.indent") {
                    state.paragraph { $0.headIndent = min(160, $0.headIndent + 20); $0.firstLineHeadIndent = $0.headIndent }
                }.frame(maxWidth: .infinity)
            }.labelStyle(.iconOnly).padding(.vertical, 12).background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30))
        .padding(.horizontal, 8)
    }
    private func preset(_ name: String, size: CGFloat, weight: UIFont.Weight = .regular) -> some View {
        Button(name) { state.attribute(.font, UIFont.systemFont(ofSize: size, weight: weight)) }
            .font(Font(UIFont.systemFont(ofSize: min(22, size), weight: weight)))
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Int(state.font.pointSize) == Int(size) ? Color.blue.opacity(0.25) : .clear, in: Capsule())
    }
    private func style(_ name: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(name, systemImage: icon, action: action).labelStyle(.iconOnly)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(active ? Color.blue.opacity(0.25) : .clear, in: Capsule())
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

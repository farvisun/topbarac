import SwiftUI
import TopbaracCore

/// First-run window: pick widgets and layout, optionally login item and shortcut, then start.
struct WelcomeView: View {
    var done: () -> Void
    @Environment(SettingsStore.self) private var settings
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text("Welcome to Topbarac").font(.system(size: 20, weight: .semibold))
                Text("Pick what to keep an eye on. You can change everything later in Settings.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)
            .padding(.horizontal, 32)

            Form {
                Section("Widgets") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(settings.settings.order) { kind in
                            WidgetChoice(kind: kind, on: Binding(get: { settings.config(kind).enabled },
                                                                 set: { on in settings.update(kind) { $0.enabled = on } }))
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Picker("Menu bar", selection: $settings.settings.mergedMode) {
                        Text("One item per widget").tag(false)
                        Text("One combined item").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in LoginItem.set(on); launchAtLogin = LoginItem.isEnabled }
                    LabeledContent("Shortcut for the overview") { HotkeyRecorder(hotkey: $settings.settings.hotkey) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Text("No accounts, no analytics. Data stays on this Mac.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Get Started", action: done)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.settings.enabledWidgets.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WidgetChoice: View {
    var kind: WidgetKind
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 8) {
                WidgetIcon(kind: kind, size: 22)
                Text(kind.title)
                Spacer(minLength: 4)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? AnyShapeStyle(kind.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(on ? kind.accent.opacity(0.1) : Color.primary.opacity(0.03), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? kind.accent.opacity(0.35) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

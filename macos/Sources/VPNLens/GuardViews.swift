import SwiftUI
import VPNLensCore

/// Выбор для одного приложения: ничего не делать, заморозить или закрыть.
enum GuardChoice: Hashable, CaseIterable, Identifiable {
    case off, freeze, quit
    var id: Self { self }

    init(_ mode: AppGuard.Mode?) {
        switch mode {
        case .freeze: self = .freeze
        case .quit: self = .quit
        case nil: self = .off
        }
    }

    var mode: AppGuard.Mode? {
        switch self {
        case .off: nil
        case .freeze: .freeze
        case .quit: .quit
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "Не трогать")
        case .freeze: String(localized: "Заморозить")
        case .quit: String(localized: "Закрыть")
        }
    }
}

/// Строка на вкладке «Сейчас»: что сделать с этим приложением, если VPN пропадёт.
/// Выбор запоминается и дальше работает всегда.
struct QuickGuardRow: View {
    let app: NSRunningApplication
    let guard_: AppGuard

    var body: some View {
        if app.activationPolicy != .regular {
            // Служебные процессы без окна (loginwindow и т.п.) не защищаем.
            EmptyView()
        } else if let reason = AppGuard.unsupportedReason(app) {
            if app.bundleIdentifier != nil {
                Row(title: String(localized: "Если VPN отключится"), leading: icon) {
                    Text(String(localized: "не поддерживается")).foregroundStyle(.tertiary)
                }
                .help(reason)
            }
        } else {
            // Подпись и сегменты на одной строке не помещаются: сегменты ниже, во всю ширину.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    icon
                    Text(String(localized: "Если VPN отключится")).font(.callout)
                }
                GuardPicker(choice: GuardChoice(guard_.mode(for: app)), fill: true) { guard_.setMode($0.mode, for: app) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .help(String(localized: "Выбор запоминается для этого приложения и срабатывает каждый раз, когда VPN отключается."))
        }
    }

    private var icon: AnyView {
        AnyView(
            Image(systemName: guard_.mode(for: app) == nil ? "shield" : "shield.lefthalf.filled")
                .foregroundStyle(guard_.mode(for: app) == nil ? Color.secondary : Color.accentColor)
                .frame(width: 16)
        )
    }
}

/// Сегменты выбора. Не выпадающий список: панель живёт внутри меню, а меню
/// в меню на macOS открывается ненадёжно.
struct GuardPicker: View {
    let choice: GuardChoice
    var options: [GuardChoice] = GuardChoice.allCases
    /// Растянуть на всю ширину строки.
    var fill = false
    /// В окне - выпадающий список, в меню - сегменты (меню в меню открывается ненадёжно).
    var popup = false
    let onChange: (GuardChoice) -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var selection: GuardChoice?

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(options) { Text($0.title).tag(Optional($0)) }
        }
        .labelsHidden()
    }

    var body: some View {
        if isSnapshot {
            // ImageRenderer не рисует NSSegmentedControl.
            HStack(spacing: 2) {
                ForEach(options) { option in
                    Text(option.title)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(option == choice ? Color(nsColor: .controlColor) : .clear))
                }
            }
            .font(.caption)
            .padding(1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        } else {
            Group {
                if popup {
                    picker.pickerStyle(.menu).fixedSize()
                } else {
                    picker
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: !fill, vertical: false)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .controlSize(fill ? .small : .mini)
                }
            }
            .onAppear { selection = choice }
            .onChange(of: choice) { _, new in selection = new }
            .onChange(of: selection) { _, new in
                if let new, new != choice { onChange(new) }
            }
        }
    }
}

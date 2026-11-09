import SwiftUI
import VPNLensCore

// Общие элементы для меню и окна.

extension EnvironmentValues {
    @Entry var isSnapshot = false
}

// MARK: - Строительные блоки

struct AppIcon: View {
    let app: NSRunningApplication?

    var body: some View {
        if let icon = app?.icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
                .padding(3)
                .foregroundStyle(.secondary)
        }
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                Spacer()
                if let trailing { Text(trailing).monospacedDigit() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
            content
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 2)
    }
}

/// Строка в стиле системных меню: подсветка при наведении, значение справа.
struct Row<Value: View>: View {
    let title: String
    var monospaced = false
    var leading: AnyView? = nil
    @ViewBuilder let value: Value

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let leading { leading }
            Text(title)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            value.font(.callout)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// Строка с адресом, который копируется по клику.
struct CopyRow: View {
    let title: String
    let value: String
    var caption: String? = nil

    @State private var copied = false

    var body: some View {
        Row(title: title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(copied ? String(localized: "Скопировано") : value)
                    .monospacedDigit()
                    .foregroundStyle(copied ? .secondary : .primary)
                    .contentTransition(.opacity)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        }
        .help(String(localized: "Нажмите, чтобы скопировать"))
    }
}

struct CheckRow: View {
    let check: LeakCheck
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: check.status.symbol)
                .foregroundStyle(check.status.tint)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.callout.weight(.medium))
                Text(check.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovered = $0 }
        .help(check.detail ?? "")
    }
}

/// Иконка приложения по идентификатору: работает и когда оно не запущено.
struct BundleIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

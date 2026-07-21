import SwiftUI
import AppKit

/// In-app dictation history — replaces the old "reveal history.jsonl in Finder".
///
/// Read-only view over HistoryStore: searchable list, newest first, with mode
/// badge, time, duration, expandable text and per-entry copy. Failures are
/// dimmed and show their error; raw-fallback results are tagged.
///
/// Entries can be injected (snapshot harness / previews); by default the view
/// loads from HistoryStore on appear.
struct HistoryView: View {

    /// nil → load from HistoryStore.shared on appear (normal app use).
    private let injectedEntries: [HistoryStore.Entry]?
    private let historyEnabled: Bool

    @State private var entries: [HistoryStore.Entry] = []
    @State private var query = ""
    @State private var confirmClear = false

    init(entries: [HistoryStore.Entry]? = nil, historyEnabled: Bool = true) {
        self.injectedEntries = entries
        self.historyEnabled = historyEnabled
    }

    private var filtered: [HistoryStore.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            ($0.final ?? "").lowercased().contains(q)
                || ($0.raw ?? "").lowercased().contains(q)
                || ($0.errorMessage ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !historyEnabled {
                disabledHint
            }

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { _, entry in
                            HistoryRow(entry: entry)
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            entries = injectedEntries ?? HistoryStore.shared.recent(limit: 1000)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(Color.teal.gradient))
            Text("Verlauf")
                .font(.title3.bold())
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Suchen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(width: 150)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - States

    private var disabledHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill").foregroundStyle(.orange)
            Text("Der Verlauf ist in den Einstellungen deaktiviert — neue Diktate werden nicht gespeichert.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: query.isEmpty ? "waveform.slash" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            Text(query.isEmpty ? "Noch keine Diktate" : "Keine Treffer für «\(query)»")
                .font(.callout)
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Drück deinen Shortcut und sprich los — jedes Diktat landet hier.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.fileURL])
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()

            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Verlauf löschen…", systemImage: "trash")
                    .font(.caption)
            }
            .disabled(entries.isEmpty)
            .confirmationDialog("Ganzen Verlauf löschen?", isPresented: $confirmClear) {
                Button("Alle \(entries.count) Einträge löschen", role: .destructive) {
                    HistoryStore.shared.clear()
                    entries = []
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die Datei wird von diesem Mac entfernt. Das kann nicht rückgängig gemacht werden.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var countLabel: String {
        if query.isEmpty {
            return entries.count == 1 ? "1 Diktat" : "\(entries.count) Diktate"
        }
        return "\(filtered.count) von \(entries.count)"
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    @State private var expanded = false
    @State private var copied = false

    private var mode: ProcessingMode? { ProcessingMode(rawValue: entry.mode) }

    private var modeColor: Color {
        switch mode {
        case .private:  return .blue
        case .business: return .indigo
        case .random:   return .pink
        case .none:     return .gray
        }
    }

    private var text: String {
        entry.final ?? entry.raw ?? entry.errorMessage ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: mode?.sfSymbol ?? "questionmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(modeColor.gradient))

                Text(mode?.displayName ?? entry.mode)
                    .font(.caption.weight(.semibold))

                Text(Self.timeLabel(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let secs = entry.audioSeconds, secs > 0 {
                    Text("\(secs) s")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary.opacity(0.5)))
                }

                if entry.usedFallback {
                    Text("Rohtext")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }

                Spacer()

                if entry.success {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Kopiert" : "Kopieren",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .secondary)
                }
            }

            if entry.success {
                Text(text)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
            } else {
                Label(entry.errorMessage ?? "Fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary.opacity(entry.success ? 0.35 : 0.2))
        )
        .opacity(entry.success ? 1 : 0.75)
    }

    /// "Heute, 14:32" / "Gestern, 09:12" / "18.07.2026, 16:45"
    static func timeLabel(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date)     { return "Heute, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Gestern, \(time)" }
        let day = date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year())
        return "\(day), \(time)"
    }
}

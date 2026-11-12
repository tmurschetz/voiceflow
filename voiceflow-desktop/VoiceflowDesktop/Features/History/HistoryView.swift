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
    enum Tab: String, CaseIterable { case dictations = "Diktate", calls = "Calls" }

    private let injectedEntries: [HistoryStore.Entry]?
    private let injectedCalls: [CallStore.Record]?
    private let historyEnabled: Bool

    @State private var entries: [HistoryStore.Entry] = []
    @State private var calls: [CallStore.Record] = []
    @State private var query = ""
    @State private var confirmClear = false
    @State private var tab: Tab

    init(entries: [HistoryStore.Entry]? = nil, calls: [CallStore.Record]? = nil,
         historyEnabled: Bool = true, tab: Tab = .dictations) {
        self.injectedEntries = entries
        self.injectedCalls = calls
        self.historyEnabled = historyEnabled
        _tab = State(initialValue: tab)
    }

    private var filteredCalls: [CallStore.Record] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return calls }
        return calls.filter {
            $0.transcript.lowercased().contains(q) || ($0.participant ?? "").lowercased().contains(q)
        }
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

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if tab == .dictations && !historyEnabled {
                disabledHint
            }

            if tab == .calls {
                if filteredCalls.isEmpty {
                    callsEmptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredCalls) { call in
                                CallRow(record: call) {
                                    CallStore.shared.delete(id: call.id)
                                    calls.removeAll { $0.id == call.id }
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            } else if filtered.isEmpty {
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
            if tab == .calls { callsFooter } else { footer }
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            entries = injectedEntries ?? HistoryStore.shared.recent(limit: 1000)
            calls = injectedCalls ?? CallStore.shared.all()
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

    private var callsEmptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: query.isEmpty ? "phone.badge.waveform" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            Text(query.isEmpty ? "Noch keine Call-Transkripte" : "Keine Treffer für «\(query)»")
                .font(.callout)
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Transcribe-Shortcut drücken oder einen Teams-Call starten — die Mitschrift landet hier und bleibt 14 Tage.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var callsFooter: some View {
        HStack(spacing: 12) {
            Text(calls.count == 1 ? "1 Call" : "\(calls.count) Calls")
                .font(.caption).foregroundStyle(.secondary)
            Text("· werden nach \(CallStore.retentionDays) Tagen automatisch gelöscht")
                .font(.caption).foregroundStyle(.tertiary)
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([CallStore.shared.baseURL])
            }
            .buttonStyle(.link)
            .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        case .dictate:    return .blue
        case .transcribe: return .teal
        case .none:       return .gray   // 1.x "business"/"random" entries
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

// MARK: - Call row

private struct CallRow: View {
    let record: CallStore.Record
    var onDelete: () -> Void
    @State private var expanded = false
    @State private var copied = false
    @State private var confirmDelete = false

    private var timeRange: String {
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        return "\(tf.string(from: record.start))–\(tf.string(from: record.end))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.teal.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.participant ?? "Call")
                        .font(.callout.weight(.semibold))
                    Text("\(HistoryRow.timeLabel(record.start).components(separatedBy: ",").first ?? ""), \(timeRange) · \(max(1, record.durationSeconds / 60)) Min"
                         + (record.source == "teams-auto" ? " · Teams" : "")
                         + (record.languages.isEmpty ? "" : " · \(record.languages.joined(separator: "+"))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if record.status == "processing" {
                    ProgressView().controlSize(.small)
                } else if record.status == "failed" {
                    Label(record.errorMessage ?? "Fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CallStore.exportText(record), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .secondary)
                }
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .confirmationDialog("Diesen Call löschen?", isPresented: $confirmDelete) {
                    Button("Löschen", role: .destructive) { onDelete() }
                    Button("Abbrechen", role: .cancel) {}
                }
            }

            if !record.transcript.isEmpty {
                Text(record.transcript)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
            }
            if record.systemAudioMissing {
                Label("Nur dein Mikrofon — Systemaudio war nicht erlaubt", systemImage: "speaker.slash")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

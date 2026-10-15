import AppKit
import SwiftUI

struct PopoverView: View {
    let rows: [UsageRow]
    let lastRefresh: Date?
    let now: Date
    let vps: VPSStatus?
    let vpsConfigured: Bool
    let vpsNote: String?
    let vpsSummary: VPSSummary
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onSignIn: () -> Void
    let onQuit: () -> Void

    /// Everything except the VPS due-date row, which lives in the VPS section.
    private var mainRows: [UsageRow] { rows.filter { $0.id != "vps" } }
    private var vpsRow: UsageRow? { rows.first { $0.id == "vps" } }

    private var openCodeNeedsSignIn: Bool {
        rows.first { $0.id == "opencode" }?.value == "needs sign-in"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("UsageBar").font(.headline)
                Spacer()
                Text(lastRefresh.map { "refreshed \(relativeAge($0, now: now))" } ?? "never refreshed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(mainRows) { row in
                        RowView(row: row, now: now)
                    }

                    Divider()

                    vpsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)

            Divider()

            HStack(spacing: 8) {
                Button("Refresh", action: onRefresh)
                Button("Settings…", action: onSettings)
                Spacer()
                // Only ask to sign in when the console actually said so; otherwise
                // the same window just opens the console page.
                Button(openCodeNeedsSignIn ? "Sign in to OpenCode…" : "Open OpenCode console…", action: onSignIn)
                Button("Quit", action: onQuit)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .padding(14)
        .frame(width: 420)
    }

    // MARK: - VPS section

    private var vpsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("VPS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cached = vps?.cachedAt {
                    Text("cached \(relativeAge(cached, now: now))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let price = vpsSummary.priceText {
                    TagBadge(tag: vpsSummary.priceTag)
                    Text(price)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let detail = vpsSummary.priceDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let vps {
                let lines = [
                    ("Disk", vps.diskLine),
                    ("RAM", vps.ramLine),
                    ("Load", vps.loadLine),
                    ("Uptime", vps.uptimeLine)
                ].compactMap { label, value in value.map { (label, $0) } }

                if lines.isEmpty {
                    Text("no VPS data in response")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lines, id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(label)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 52, alignment: .leading)
                            Text(value)
                                .font(.system(size: 12))
                        }
                    }
                }
            } else if !vpsConfigured {
                Text("VPS endpoint not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let vpsNote {
                Text(vpsNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let renewal = vpsSummary.renewalText {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TagBadge(tag: vpsSummary.renewalTag)
                    Text(renewal)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let vpsRow {
                RowView(row: vpsRow, now: now)
            }
        }
    }
}

struct RowView: View {
    let row: UsageRow
    let now: Date
    @State private var showDebug = false

    /// Stale values are greyed so a frozen number never reads as current
    /// (SPEC §17); an alert still wins so due-date warnings stay orange.
    private var isStale: Bool { row.isStale(now: now) }

    private var valueColor: Color {
        if row.alert { return .orange }
        return isStale ? .secondary : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RowLogo(rowID: row.id)
                Text(row.title)
                    .font(.system(size: 12, weight: .semibold))
                TagBadge(tag: row.tag)
                if isStale {
                    Text("STALE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.gray.opacity(0.22), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help("Older than this row's freshness budget — the value may have moved on")
                }
                Spacer()
                Text(isStale ? "⚠︎ \(updatedText(row.updated, now: now))" : updatedText(row.updated, now: now))
                    .font(.caption2)
                    .foregroundStyle(isStale ? Color.orange : Color.secondary)
            }

            Text(row.value)
                .font(.system(size: 13))
                .foregroundStyle(valueColor)

            if let footnote = row.footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let debug = row.debug, !debug.isEmpty {
                DisclosureGroup(isExpanded: $showDebug) {
                    Text(debug)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("debug").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// 14pt service logo to the left of a row title (SPEC §15). Falls back to an
/// SF Symbol when the bundled logo is missing; the spend row always uses a
/// symbol instead of a service logo.
struct RowLogo: View {
    let rowID: String

    var body: some View {
        Group {
            if let name = Logos.assetName(forRowID: rowID), let image = Logos.image(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: Logos.rowSymbol(forRowID: rowID))
                    .font(.system(size: 12))
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct TagBadge: View {
    let tag: SourceTag

    var body: some View {
        Text(tag.rawValue)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch tag {
        case .live: return Color.green.opacity(0.18)
        case .estimated: return Color.blue.opacity(0.18)
        case .manual: return Color.orange.opacity(0.18)
        case .list: return Color.purple.opacity(0.18)
        case .none: return Color.gray.opacity(0.14)
        }
    }

    private var foreground: Color {
        switch tag {
        case .live: return .green
        case .estimated: return .blue
        case .manual: return .orange
        case .list: return .purple
        case .none: return .secondary
        }
    }
}

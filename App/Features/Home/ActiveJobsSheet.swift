import PixlModel
import SwiftUI

/// Android `JobsBottomSheet`: "Active jobs", then one row per thing that is running or waiting — a progress ring (or a
/// spinner, a clock for a job still waiting its turn), the job's label, its detail line and a linear bar when the
/// percentage is known — with Liquid Glass cards in place of the plain rows. Below the active ones, what finished in the
/// last day ("Recently finished": done, or needing you), so the sheet still has something to say when the app comes
/// back after jobs moved on while it was closed. A Cloud row opens the Cloud queue, where its songs can be retried or
/// cancelled.
///
/// Nothing can get stuck here (docs/handoff/2026-10-09-many-jobs-fix.md): "Cancel all" (with a confirmation) stops every
/// running and waiting job through its own source, "Clear finished" empties "Recently finished" (done and failed rows,
/// all of them, not only the few listed), a finished row has its own Dismiss, a failed row Retry where its source can
/// start the work again, and a running row can be cancelled from its context menu.
///
/// Everything it shows is read from `ActiveJobs.active` / `.recent`: the aggregator follows the sources while the sheet is up and
/// costs nothing when it is closed.
struct ActiveJobsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var confirmsCancelAll = false

    var body: some View {
        let jobs = env.activeJobs
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Active jobs")
                        .pixlFont(.titleLarge, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if !jobs.active.isEmpty {
                        GlassPillButton(title: "Cancel all", systemImage: "xmark.circle",
                                        tint: theme.errorContainer.opacity(GlassTint.container),
                                        foreground: theme.onErrorContainer, style: .labelMedium, iconSize: 15,
                                        horizontalPadding: 12, verticalPadding: 8) { confirmsCancelAll = true }
                            .accessibilityHint("Stops everything that is running or waiting")
                            .accessibilityIdentifier("jobs.cancelAll")
                    }
                }
                .padding(.bottom, 2)
                if jobs.active.isEmpty {
                    emptyState
                } else {
                    ForEach(jobs.active) { job in row(job) }
                }
                if !jobs.recent.isEmpty {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Recently finished")
                            .pixlFont(.labelLarge)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        GlassPillButton(title: "Clear finished", systemImage: "trash",
                                        tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                                        foreground: theme.onSurface, style: .labelMedium, iconSize: 14,
                                        horizontalPadding: 12, verticalPadding: 8) { jobs.clearFinished() }
                            .accessibilityHint("Removes every finished and failed job from the list")
                            .accessibilityIdentifier("jobs.clearFinished")
                    }
                    .padding(.top, 14)
                    ForEach(jobs.recent) { job in row(job) }
                    if jobs.finishedCount > jobs.recent.count {
                        Text("and \(jobs.finishedCount - jobs.recent.count) more finished")
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                            .padding(.horizontal, 4)
                            .accessibilityIdentifier("jobs.moreFinished")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The stored Cloud jobs, in case the sheet opens before anything else asked for them.
        .task { await env.cloud.loadForDisplay() }
        // The aggregator follows every row's source (at most 4 Hz) only while this is on screen.
        .onAppear { env.activeJobs.setSheetVisible(true) }
        .onDisappear { env.activeJobs.setSheetVisible(false) }
        .alert("Cancel all jobs?", isPresented: $confirmsCancelAll) {
            Button("Cancel all", role: .destructive) { env.activeJobs.cancelAll() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Everything running or waiting stops, and downloads and scans are abandoned. Finished work stays.")
        }
    }

    private func row(_ job: ActiveJob) -> some View {
        let jobs = env.activeJobs
        return ActiveJobRow(job: job, onOpen: { open(job) }, onDismiss: { jobs.dismiss(job) },
                            onRetry: { jobs.retry(job) }, onCancel: { jobs.cancel(job) })
            .equatable()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                .accessibilityHidden(true)
            Text("Nothing running right now.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            Text("Syncing, downloads and cloud processing show up here while they work.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("jobs.empty")
    }

    private func open(_ job: ActiveJob) {
        switch job.destination {
        case .none:
            break
        case .cloudQueue:
            router.dismissSheet()
            if router.currentPath.last != .cloudQueue { router.push(.cloudQueue) }
        }
    }
}

/// One job: a glass card, tappable when it has somewhere to go, with Retry and Dismiss on the trailing edge once it has
/// finished (plain fills, not glass: they sit on a glass card) and Cancel in the context menu while it runs.
private struct ActiveJobRow: View, Equatable {
    let job: ActiveJob
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void

    /// The action closures are new on every parent pass: only the job decides whether the row re-renders.
    nonisolated static func == (lhs: ActiveJobRow, rhs: ActiveJobRow) -> Bool { lhs.job == rhs.job }

    @Environment(\.appTheme) private var theme

    private var canRetry: Bool { job.state == .failed && job.canRetry }

    var body: some View {
        HStack(spacing: 10) {
            main
            if job.isFinished { finishedActions }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: tint,
                   interactive: job.destination != .none)
        .contextMenu {
            if job.isActive {
                Button("Cancel", systemImage: "xmark.circle", role: .destructive, action: onCancel)
            } else {
                if canRetry { Button("Retry", systemImage: "arrow.clockwise", action: onRetry) }
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
            }
        }
    }

    /// The row's words, and the tap to wherever the job lives when it has somewhere to go.
    @ViewBuilder
    private var main: some View {
        let element = Group {
            if job.destination == .none {
                content
            } else {
                Button(action: onOpen) { content.contentShape(Rectangle()) }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActiveJobBoard.accessibilityLabel(job))
        .accessibilityAddTraits(job.destination == .none ? [] : .isButton)
        .accessibilityHint(job.destination == .cloudQueue ? "Opens the cloud queue" : "")
        .accessibilityIdentifier("jobs.row.\(job.id)")
        if job.isActive {
            element.accessibilityAction(named: "Cancel") { onCancel() }
        } else if canRetry {
            element
                .accessibilityAction(named: "Retry") { onRetry() }
                .accessibilityAction(named: "Dismiss") { onDismiss() }
        } else {
            element.accessibilityAction(named: "Dismiss") { onDismiss() }
        }
    }

    private var finishedActions: some View {
        HStack(spacing: 8) {
            if canRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .pixlFont(.labelMedium, weight: .semibold)
                        .foregroundStyle(theme.onSecondaryContainer)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(theme.secondaryContainer, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
                .accessibilityLabel("Retry")
                .accessibilityIdentifier("jobs.retry.\(job.id)")
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .background(theme.surfaceContainerHighest.opacity(0.6), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.9))
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("jobs.dismiss.\(job.id)")
        }
    }

    private var tint: Color {
        let role = job.state == .failed ? theme.errorContainer : theme.surfaceContainerHigh
        return role.opacity(job.state == .failed ? GlassTint.surface + 0.2 : GlassTint.surface + 0.1)
    }

    private var content: some View {
        HStack(spacing: 14) {
            leading
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .pixlFont(.bodyLarge, weight: .medium)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                if let subtitle = job.subtitle ?? (job.state == .queued ? "Queued" : nil) {
                    Text(subtitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(job.state == .failed ? theme.error : theme.onSurfaceVariant)
                        .lineLimit(3)
                }
                if let percent = job.percent, job.isActive {
                    ProgressView(value: Double(percent), total: 100)
                        .tint(theme.primary)
                        .padding(.top, 6)
                        .animation(.linear(duration: 0.2), value: percent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if job.destination != .none {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                .accessibilityHidden(true)
        } else if let percent = job.percent, job.isActive {
            Text("\(percent)%")
                .pixlFont(.labelMedium)
                .monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    /// Android's leading element: a ring when the percentage is known (here with the kind's symbol in it), a spinner
    /// while running without one, a clock while waiting, a check or a warning once finished.
    @ViewBuilder
    private var leading: some View {
        switch job.state {
        case .running:
            if let percent = job.percent {
                ZStack {
                    Circle().stroke(theme.primary.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(percent) / 100)
                        .stroke(theme.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: percent)
                    Image(systemName: job.kind.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
                .padding(2)
            } else {
                ProgressView().tint(theme.primary)
            }
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 22))
                .foregroundStyle(theme.onSurfaceVariant)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(theme.primary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(theme.error)
        }
    }
}

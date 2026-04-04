import Observation
import SwiftUI

struct DashboardView: View {
    @Bindable var model: AppModel

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    var body: some View {
        ZStack {
            background

            GeometryReader { proxy in
                let compactLayout = proxy.size.width < 430

                ScrollView {
                    VStack(spacing: 18) {
                        heroCard(compact: compactLayout)
                        actionCard
                        metricsCard(compact: compactLayout)
                        uploadsCard
                        noteCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            headerBar
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.97, blue: 1.0),
                Color(red: 0.98, green: 0.94, blue: 0.88),
                Color(red: 0.86, green: 0.93, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 220, height: 220)
                .blur(radius: 18)
                .offset(x: 70, y: -50)
        }
    }

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Photo Sync")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(buildCaption)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                ViewThatFits {
                    HStack(spacing: 10) {
                        retryButton
                        signOutButton
                    }

                    signOutButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Divider()
                .overlay(.white.opacity(0.45))
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var retryButton: some View {
        if model.canRetry {
            Button("Retry") {
                model.retrySync()
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.65), in: Capsule())
        }
    }

    @ViewBuilder
    private var signOutButton: some View {
        if model.canSignOut {
            Button("Sign Out") {
                model.signOut()
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(Color(red: 0.08, green: 0.41, blue: 0.86))
        }
    }

    @ViewBuilder
    private func heroCard(compact: Bool) -> some View {
        CardShell {
            if compact {
                VStack(alignment: .leading, spacing: 16) {
                    ProgressRing(progress: model.syncMetrics.progressFraction)
                        .frame(width: 92, height: 92)

                    heroTextBlock(titleSize: 24)
                    heroBadges
                }
            } else {
                HStack(alignment: .center, spacing: 18) {
                    ProgressRing(progress: model.syncMetrics.progressFraction)
                        .frame(width: 122, height: 122)

                    VStack(alignment: .leading, spacing: 10) {
                        heroTextBlock(titleSize: 28)
                        heroBadges
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }
            }
        }
    }

    private var actionCard: some View {
        CardShell {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Control Center")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Spacer()
                    statusChip
                }

                Button {
                    Task {
                        await model.performPrimaryAction()
                    }
                } label: {
                    HStack {
                        Image(systemName: model.isSignedIn ? "arrow.triangle.2.circlepath.circle.fill" : "person.badge.key.fill")
                        Text(model.primaryActionTitle)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.primaryActionDisabled)

                if let error = model.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func metricsCard(compact: Bool) -> some View {
        CardShell {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sync Metrics")
                    .font(.system(.title3, design: .rounded).weight(.bold))

                if compact {
                    VStack(spacing: 12) {
                        metricTiles
                    }
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        metricTiles
                    }
                }

                if let currentFileName = model.syncMetrics.currentFileName {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.syncMetrics.currentItemLabel)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(progressCaption)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        }

                        Text(currentFileName)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        ProgressView(value: model.syncMetrics.currentItemProgressFraction)
                            .tint(Color(red: 0.15, green: 0.48, blue: 0.87))
                    }
                }
            }
        }
    }

    private var uploadsCard: some View {
        CardShell {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recent Uploads")
                    .font(.system(.title3, design: .rounded).weight(.bold))

                if model.recentUploads.isEmpty {
                    Text("Uploaded items will appear here after the first successful sync.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.recentUploads) { upload in
                        HStack(alignment: .center, spacing: 12) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.75))
                                .frame(width: 42, height: 42)
                                .overlay {
                                    Image(systemName: "photo.stack.fill")
                                        .foregroundStyle(Color(red: 0.16, green: 0.44, blue: 0.83))
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(upload.fileName)
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .lineLimit(1)
                                Text(upload.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let productURL = upload.productURL {
                                Link(destination: productURL) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 18, weight: .semibold))
                                }
                                .foregroundStyle(Color(red: 0.16, green: 0.44, blue: 0.83))
                            }
                        }

                        if upload.id != (model.recentUploads.last?.id ?? upload.id) {
                            Divider()
                                .overlay(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private var noteCard: some View {
        CardShell {
            VStack(alignment: .leading, spacing: 10) {
                Text("Implementation Notes")
                    .font(.system(.title3, design: .rounded).weight(.bold))

                Text("Google Photos now limits the Library API to app-created content. This app uses a user-initiated upload flow, tracks already-uploaded Apple Photos locally on-device, and resumes incrementally on future launches.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Long-running background sync is best-effort on iOS. The app continues while iOS grants background time, then resumes quickly the next time the app becomes active.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var metricTiles: some View {
        MetricTile(
            label: "Uploaded",
            value: "\(model.uploadedCount)",
            footnote: "of \(model.totalLibraryCount)"
        )
        MetricTile(
            label: "Pending",
            value: "\(model.pendingCount)",
            footnote: model.isSyncing ? "live queue" : "waiting"
        )
        MetricTile(
            label: "Transferred",
            value: byteFormatter.string(fromByteCount: model.syncMetrics.uploadedBytes),
            footnote: totalByteCaption
        )
        MetricTile(
            label: "ETA",
            value: etaCaption,
            footnote: speedCaption
        )
    }

    private func heroTextBlock(titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.statusTitle)
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.17, blue: 0.25))
                .fixedSize(horizontal: false, vertical: true)

            Text(model.statusDetail)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroBadges: some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 10) {
                photoBadge
                accountBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                photoBadge
                accountBadge
            }
        }
    }

    private var photoBadge: some View {
        Label(
            model.photoAccessState.isGranted ? "Photos Ready" : "Photos Locked",
            systemImage: model.photoAccessState.isGranted ? "checkmark.shield.fill" : "lock.fill"
        )
        .modifier(
            PillStyle(
                fill: model.photoAccessState.isGranted ? Color.green.opacity(0.16) : Color.orange.opacity(0.16),
                foreground: model.photoAccessState.isGranted ? .green : .orange
            )
        )
    }

    @ViewBuilder
    private var accountBadge: some View {
        if let email = model.userProfile?.email {
            Label(email, systemImage: "person.crop.circle.fill")
                .modifier(PillStyle(fill: Color.blue.opacity(0.12), foreground: Color.blue))
        }
    }

    private var totalByteCaption: String {
        guard model.syncMetrics.estimatedTotalBytes > 0 else {
            return "estimating"
        }

        return "of \(byteFormatter.string(fromByteCount: model.syncMetrics.estimatedTotalBytes))"
    }

    private var etaCaption: String {
        guard let eta = model.syncMetrics.estimatedRemainingSeconds,
              let rendered = durationFormatter.string(from: eta) else {
            return model.isSyncing ? "estimating" : "ready"
        }

        return rendered
    }

    private var speedCaption: String {
        guard let speed = model.syncMetrics.bytesPerSecond else {
            return model.isSyncing ? "warming up" : "idle"
        }

        return "\(byteFormatter.string(fromByteCount: Int64(speed)))/s"
    }

    private var progressCaption: String {
        "\(Int(model.syncMetrics.currentItemProgressFraction * 100))%"
    }

    private var buildCaption: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private var statusChip: some View {
        Text(statusText)
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(statusColor.opacity(0.16))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusText: String {
        switch model.syncMetrics.phase {
        case .idle:
            return "Idle"
        case .awaitingPermissions:
            return "Permissions"
        case .preparing:
            return "Preparing"
        case .uploading:
            return "Uploading"
        case .syncingComplete:
            return "Complete"
        case .failed:
            return "Error"
        }
    }

    private var statusColor: Color {
        switch model.syncMetrics.phase {
        case .idle:
            return .blue
        case .awaitingPermissions:
            return .orange
        case .preparing:
            return .yellow
        case .uploading:
            return Color(red: 0.13, green: 0.52, blue: 0.82)
        case .syncingComplete:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct CardShell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.4), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 22, x: 0, y: 14)
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(footnote)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.12, green: 0.53, blue: 0.88),
                            Color(red: 0.97, green: 0.62, blue: 0.18),
                            Color(red: 0.37, green: 0.74, blue: 0.35)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 6) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("synced")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PillStyle: ViewModifier {
    let fill: Color
    let foreground: Color

    func body(content: Content) -> some View {
        content
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(fill, in: Capsule())
            .foregroundStyle(foreground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.45, blue: 0.85),
                                Color(red: 0.05, green: 0.29, blue: 0.67)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

import SwiftUI
import Observation
import RigidRingBufferKit

// MARK: - App entry

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            PipelineView()
                .tabItem { Label("Pipeline", systemImage: "arrow.triangle.merge") }
            BenchmarkView()
                .tabItem { Label("Benchmark", systemImage: "speedometer") }
        }
    }
}

// MARK: - Live pipeline demo

/// Drives a live telemetry pipeline: a producer task pushes simulated events into
/// the actor-isolated `EventPipeline` (backed by the noncopyable ring buffer),
/// while an optional drain loop consumes batches. Toggling the drain loop off
/// demonstrates overflow behavior — watch evictions/rejections climb while the
/// occupancy gauge pins at capacity.
@MainActor
@Observable
final class PipelineModel {
    private(set) var metrics = BufferMetrics()
    private(set) var occupancy = 0
    private(set) var recentDrained: [TelemetryEvent] = []
    private(set) var isRunning = false

    let capacity = 64
    var policy: OverflowPolicy = .dropOldest
    var drainEnabled = true

    private var pipeline: EventPipeline<TelemetryEvent>?
    private var producerTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var nextID: UInt64 = 0

    private static let sampleNames: [(String, TelemetryEvent.Severity)] = [
        ("screen_view", .info),
        ("http_request", .debug),
        ("cache_miss", .debug),
        ("slow_frame", .warning),
        ("http_request_failed", .error),
        ("user_tap", .info),
    ]

    func start() {
        guard !isRunning else { return }
        guard let pipeline = EventPipeline<TelemetryEvent>(capacity: capacity, policy: policy) else {
            // Unreachable with the hardcoded positive capacity, but the failable
            // init is honored rather than force-unwrapped.
            return
        }
        self.pipeline = pipeline
        isRunning = true

        producerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.produceBurst()
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.drainIfEnabled()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func stop() {
        producerTask?.cancel()
        drainTask?.cancel()
        producerTask = nil
        drainTask = nil
        isRunning = false
    }

    func reset() {
        stop()
        pipeline = nil
        metrics = BufferMetrics()
        occupancy = 0
        recentDrained = []
        nextID = 0
    }

    private func produceBurst() async {
        guard let pipeline else { return }
        // Small randomized burst so the gauge visibly breathes.
        let burst = Int.random(in: 2...6)
        for _ in 0..<burst {
            // sampleNames is a non-empty constant; randomElement is still handled
            // defensively rather than force-unwrapped.
            let sample = Self.sampleNames.randomElement() ?? ("event", .info)
            let event = TelemetryEvent(
                id: nextID,
                name: sample.0,
                timestamp: Date().timeIntervalSinceReferenceDate,
                severity: sample.1
            )
            nextID &+= 1
            await pipeline.ingest(event)
        }
        await refreshStats()
    }

    private func drainIfEnabled() async {
        guard let pipeline, drainEnabled else { return }
        let batch = await pipeline.drainBatch(max: 32)
        if !batch.isEmpty {
            // Keep the most recent 20 for display; suffix is safe on any count.
            recentDrained = Array((recentDrained + batch).suffix(20))
        }
        await refreshStats()
    }

    private func refreshStats() async {
        guard let pipeline else { return }
        metrics = await pipeline.metrics()
        occupancy = await pipeline.count
    }
}

struct PipelineView: View {
    @State private var model = PipelineModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Buffer") {
                    occupancyGauge
                    Picker("Overflow policy", selection: $model.policy) {
                        Text("Drop oldest").tag(OverflowPolicy.dropOldest)
                        Text("Reject newest").tag(OverflowPolicy.rejectNewest)
                    }
                    .disabled(model.isRunning)
                    Toggle("Drain loop running", isOn: $model.drainEnabled)
                }

                Section("Metrics") {
                    metricRow("Pushed", model.metrics.totalPushed)
                    metricRow("Evicted (drop-oldest)", model.metrics.totalEvicted)
                    metricRow("Rejected (reject-newest)", model.metrics.totalRejected)
                    metricRow("Drained", model.metrics.totalDrained)
                    metricRow("High-water mark", model.metrics.highWaterMark)
                }

                Section("Recently drained") {
                    if model.recentDrained.isEmpty {
                        Text(model.isRunning
                             ? "Waiting for the first drain batch…"
                             : "Start the pipeline to see drained events.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentDrained) { event in
                            HStack {
                                Circle()
                                    .fill(color(for: event.severity))
                                    .frame(width: 8, height: 8)
                                Text(event.name)
                                Spacer()
                                Text("#\(event.id)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle("RigidRingBuffer")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.isRunning ? "Stop" : "Start") {
                        if model.isRunning {
                            model.stop()
                        } else {
                            model.start()
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { model.reset() }
                        .disabled(model.isRunning)
                }
            }
        }
    }

    private var occupancyGauge: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Occupancy")
                Spacer()
                Text("\(model.occupancy) / \(model.capacity)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // capacity is a positive constant; the max(1, _) guard keeps the
            // division safe under any future refactor.
            ProgressView(value: Double(model.occupancy), total: Double(max(1, model.capacity)))
                .tint(model.occupancy >= model.capacity ? .red : .accentColor)
        }
    }

    private func metricRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func color(for severity: TelemetryEvent.Severity) -> Color {
        switch severity {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Benchmark demo

@MainActor
@Observable
final class BenchmarkModel {
    private(set) var reports: [BufferBenchmark.Report] = []
    private(set) var isRunning = false

    func run() {
        guard !isRunning else { return }
        isRunning = true
        reports = []
        let config = BufferBenchmark.Configuration(
            events: 120_000,
            capacity: 1_024,
            batchInterval: 256,
            payloadBallast: 8
        )
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = BufferBenchmark.runFullComparison(config)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reports = results
                self.isRunning = false
            }
        }
    }
}

struct BenchmarkView: View {
    @State private var model = BenchmarkModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.run()
                    } label: {
                        if model.isRunning {
                            HStack {
                                ProgressView()
                                Text("Running four scenarios…")
                            }
                        } else {
                            Text("Run rigid vs. COW comparison")
                        }
                    }
                    .disabled(model.isRunning)
                } footer: {
                    Text("120k reference-payload events per scenario. The steady-state pair is the equal-work comparison; the snapshot pair contrasts the accidental COW-sharing pattern with the drain handoff the noncopyable type forces instead.")
                }

                if !model.reports.isEmpty {
                    Section("Results") {
                        ForEach(Array(model.reports.enumerated()), id: \.offset) { _, report in
                            reportRow(report)
                        }
                    }
                }
            }
            .navigationTitle("Benchmark")
        }
    }

    @ViewBuilder
    private func reportRow(_ report: BufferBenchmark.Report) -> some View {
        // Bars are scaled against the best throughput; guard division by zero
        // (can only occur if every run reported zero throughput).
        let best = model.reports.map(\.eventsPerSecond).max() ?? 0
        let fraction = best > 0 ? report.eventsPerSecond / best : 0
        VStack(alignment: .leading, spacing: 6) {
            Text(report.name)
                .font(.subheadline)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 3)
                    .fill(report.name.hasPrefix("Rigid") ? Color.green : Color.orange)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
            .frame(height: 10)
            HStack {
                Text("\(Int(report.eventsPerSecond).formatted()) events/s")
                    .monospacedDigit()
                Spacer()
                if report.evicted > 0 {
                    Text("\(report.evicted.formatted()) evicted")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

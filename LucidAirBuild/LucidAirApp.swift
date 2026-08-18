import SwiftUI
import AVFoundation
import Combine

enum InductionMethod: String, CaseIterable, Identifiable {
    case mild = "MILD"
    case ssild = "SSILD"
    var id: String { rawValue }
}

enum TonePreset: String, CaseIterable, Identifiable {
    case theta4 = "4 Hz Theta"
    case theta6 = "6 Hz Theta"
    case alpha10 = "10 Hz Alpha"
    case gamma40 = "40 Hz Gamma"
    var id: String { rawValue }
    var hz: Double {
        switch self {
        case .theta4: return 4
        case .theta6: return 6
        case .alpha10: return 10
        case .gamma40: return 40
        }
    }
}

@MainActor
final class AirPodsRouteGuard: ObservableObject {
    @Published private(set) var routeName = "No audio route"
    @Published private(set) var isBluetoothAudio = false
    @Published private(set) var isAirPodsRoute = false
    @Published private(set) var isAllowedRoute = false
    @Published var strictAirPodsOnly = true
    @Published private(set) var statusMessage = "Connect AirPods"

    private let audioSession = AVAudioSession.sharedInstance()
    private var routeCancellable: AnyCancellable?

    func configure() {
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            statusMessage = "Audio session error: \(error.localizedDescription)"
        }

        routeCancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        refresh()
    }

    func refresh() {
        let output = audioSession.currentRoute.outputs.first
        routeName = output?.portName ?? "No output"
        let bluetoothTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        isBluetoothAudio = output.map { bluetoothTypes.contains($0.portType) } ?? false
        isAirPodsRoute = isBluetoothAudio && routeName.localizedCaseInsensitiveContains("AirPods")
        isAllowedRoute = strictAirPodsOnly ? isAirPodsRoute : isBluetoothAudio

        if isAllowedRoute {
            statusMessage = "Safe route: \(routeName)"
        } else if isBluetoothAudio {
            statusMessage = strictAirPodsOnly ? "Bluetooth connected, but not identified as AirPods" : "Bluetooth route allowed"
        } else {
            statusMessage = "Speaker fallback BLOCKED"
        }
    }
}

@MainActor
final class ToneEngine: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var label = "Stopped"

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100

    init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func playIsochronic(rateHz: Double, carrierHz: Double = 220, volume: Float = 0.16) {
        stop()
        guard let buffer = isochronicBuffer(rateHz: rateHz, carrierHz: carrierHz, seconds: 4) else { return }
        start(buffer: buffer, volume: volume, label: "\(Int(rateHz)) Hz isochronic")
    }

    func playAlarm() {
        stop()
        guard let buffer = alarmBuffer(seconds: 3) else { return }
        start(buffer: buffer, volume: 0.38, label: "AirPods alarm")
    }

    func playBackgroundGuard() {
        stop()
        guard let buffer = silentBuffer(seconds: 4) else { return }
        start(buffer: buffer, volume: 1.0, label: "Silent night guard")
    }

    func stop() {
        player.stop()
        engine.stop()
        isPlaying = false
        label = "Stopped"
    }

    private func start(buffer: AVAudioPCMBuffer, volume: Float, label: String) {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            player.volume = volume
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isPlaying = true
            self.label = label
        } catch {
            isPlaying = false
            self.label = "Audio error: \(error.localizedDescription)"
        }
    }

    private func isochronicBuffer(rateHz: Double, carrierHz: Double, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let carrier = sin(twoPi * carrierHz * t)
            let lfo = sin(twoPi * rateHz * t)
            let envelope = pow(max(0, (lfo + 1) * 0.5), 2.2)
            data[i] = Float(carrier * envelope * 0.8)
        }
        return buffer
    }

    private func alarmBuffer(seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let pulse = pow(max(0, sin(twoPi * 1.8 * t)), 2.0)
            let tone = 0.75 * sin(twoPi * 660 * t) + 0.25 * sin(twoPi * 880 * t)
            data[i] = Float(tone * pulse * 0.65)
        }
        return buffer
    }

    private func silentBuffer(seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { data[i] = 0 }
        return buffer
    }
}

@MainActor
final class SleepSessionManager: ObservableObject {
    @Published private(set) var isArmed = false
    @Published private(set) var alarmFiring = false
    @Published private(set) var targetDate: Date?
    @Published private(set) var lastEvent = "Not armed"
    @Published var useBackgroundGuard = true
    @Published var cycleMinutes = 90
    @Published var cycles = 5

    private weak var routeGuard: AirPodsRouteGuard?
    private weak var audio: ToneEngine?
    private var timer: DispatchSourceTimer?
    private var cancellable: AnyCancellable?

    func attach(routeGuard: AirPodsRouteGuard, audio: ToneEngine) {
        self.routeGuard = routeGuard
        self.audio = audio
        cancellable = routeGuard.$isAllowedRoute
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] allowed in
                Task { @MainActor in self?.routeDidChange(allowed: allowed) }
            }
    }

    func arm() {
        guard let routeGuard, routeGuard.isAllowedRoute else {
            lastEvent = "Not armed — connect the allowed AirPods route first."
            return
        }
        schedule(after: TimeInterval(cycles * cycleMinutes * 60), isTest: false)
    }

    func armTest(seconds: Int = 12) {
        guard let routeGuard, routeGuard.isAllowedRoute else {
            lastEvent = "Test blocked — no allowed AirPods route."
            return
        }
        schedule(after: TimeInterval(seconds), isTest: true)
    }

    func stopAlarm() {
        audio?.stop()
        alarmFiring = false
        isArmed = false
        targetDate = nil
        lastEvent = "Alarm stopped — begin an induction guide."
        cancelTimerOnly()
    }

    func cancel() {
        audio?.stop()
        isArmed = false
        alarmFiring = false
        targetDate = nil
        lastEvent = "Cancelled"
        cancelTimerOnly()
    }

    private func schedule(after interval: TimeInterval, isTest: Bool) {
        cancelTimerOnly()
        targetDate = Date().addingTimeInterval(interval)
        isArmed = true
        alarmFiring = false
        let minutes = Int(interval / 60)
        lastEvent = isTest ? "Test alarm armed for \(Int(interval)) seconds." : "Armed for \(minutes / 60)h \(minutes % 60)m from now."
        if useBackgroundGuard { audio?.playBackgroundGuard() }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.fireIfSafe() }
        }
        timer = source
        source.resume()
    }

    private func fireIfSafe() {
        guard isArmed else { return }
        guard let routeGuard, routeGuard.isAllowedRoute else {
            audio?.stop()
            alarmFiring = false
            isArmed = false
            targetDate = nil
            lastEvent = "Alarm SUPPRESSED because AirPods were not the active route."
            cancelTimerOnly()
            return
        }
        audio?.playAlarm()
        alarmFiring = true
        lastEvent = "Alarm playing through \(routeGuard.routeName)."
    }

    private func routeDidChange(allowed: Bool) {
        guard isArmed || alarmFiring else { return }
        if !allowed {
            audio?.stop()
            alarmFiring = false
            lastEvent = "Audio stopped: allowed AirPods route disappeared."
        } else if isArmed && useBackgroundGuard && !alarmFiring {
            audio?.playBackgroundGuard()
            lastEvent = "Allowed AirPods route restored. Silent night guard resumed."
        }
    }

    private func cancelTimerOnly() {
        timer?.cancel()
        timer = nil
    }
}

@MainActor
final class GuideManager: ObservableObject {
    @Published private(set) var isGuiding = false
    @Published private(set) var currentStep = "Ready"

    private weak var routeGuard: AirPodsRouteGuard?
    private weak var audio: ToneEngine?
    private let speech = AVSpeechSynthesizer()
    private var task: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    func attach(routeGuard: AirPodsRouteGuard, audio: ToneEngine) {
        self.routeGuard = routeGuard
        self.audio = audio
        cancellable = routeGuard.$isAllowedRoute
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] allowed in
                guard !allowed else { return }
                Task { @MainActor in self?.stopBecauseRouteWasLost() }
            }
    }

    func startMILD(wakeMinutes: Int = 8, toneAfterHz: Double? = 6) {
        stop()
        guard routeGuard?.isAllowedRoute == true else {
            currentStep = "Guide blocked — AirPods route required."
            return
        }
        isGuiding = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.say("You are awake for a lucid dreaming attempt. Keep the room dark and stay relaxed. Recall the dream you were just having.")
            await self.pause(8)
            await self.say("Choose one clear moment from that dream. Imagine returning to it. Notice something unusual, and imagine realizing: I am dreaming.")
            await self.pause(10)
            await self.say("Repeat silently: next time I am dreaming, I will remember that I am dreaming. Mean the words rather than repeating them mechanically.")

            let remaining = max(0, wakeMinutes * 60 - 70)
            if remaining > 0 {
                self.currentStep = "Stay gently awake for about \(max(1, remaining / 60)) more minute(s)."
                await self.pause(Double(remaining))
            }

            guard !Task.isCancelled, self.routeGuard?.isAllowedRoute == true else { return }
            await self.say("Now return to sleep while replaying the dream scene and the moment of becoming lucid.")
            if let hz = toneAfterHz, self.routeGuard?.isAllowedRoute == true {
                self.audio?.playIsochronic(rateHz: hz, volume: 0.08)
                self.currentStep = "Optional \(Int(hz)) Hz tone playing quietly. Stop it whenever you want to sleep."
            } else {
                self.currentStep = "MILD complete. Return to sleep."
            }
            self.isGuiding = false
        }
    }

    func startSSILD() {
        stop()
        guard routeGuard?.isAllowedRoute == true else {
            currentStep = "Guide blocked — AirPods route required."
            return
        }
        isGuiding = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.say("SSILD. Get comfortable and close your eyes. You will cycle gently through sight, hearing, and body sensations.")
            for cycle in 1...4 {
                guard !Task.isCancelled, self.routeGuard?.isAllowedRoute == true else { return }
                self.currentStep = "SSILD cycle \(cycle) of 4 — sight"
                await self.say("Notice the darkness behind your eyelids. Do not strain to see anything.")
                await self.pause(cycle < 3 ? 8 : 16)
                self.currentStep = "SSILD cycle \(cycle) of 4 — hearing"
                await self.say("Notice sounds. Near sounds, distant sounds, or the quiet itself.")
                await self.pause(cycle < 3 ? 8 : 16)
                self.currentStep = "SSILD cycle \(cycle) of 4 — body"
                await self.say("Notice body sensations: pressure, warmth, breathing, tingling, or weight.")
                await self.pause(cycle < 3 ? 8 : 16)
            }
            await self.say("The cycles are complete. Stop trying now and allow yourself to fall asleep naturally.")
            self.currentStep = "SSILD complete. Return to sleep."
            self.isGuiding = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        speech.stopSpeaking(at: .immediate)
        audio?.stop()
        isGuiding = false
        currentStep = "Ready"
    }

    private func stopBecauseRouteWasLost() {
        guard isGuiding || speech.isSpeaking else { return }
        task?.cancel()
        task = nil
        speech.stopSpeaking(at: .immediate)
        audio?.stop()
        isGuiding = false
        currentStep = "Guide stopped because the AirPods route disappeared."
    }

    private func say(_ text: String) async {
        guard !Task.isCancelled, routeGuard?.isAllowedRoute == true else { return }
        currentStep = text
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.44
        utterance.volume = 0.72
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
        let seconds = max(2.5, Double(text.split(separator: " ").count) * 0.38)
        await pause(seconds)
    }

    private func pause(_ seconds: Double) async {
        guard seconds > 0 else { return }
        let nanos = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
}

struct ContentView: View {
    @EnvironmentObject private var route: AirPodsRouteGuard
    @EnvironmentObject private var audio: ToneEngine
    @EnvironmentObject private var session: SleepSessionManager
    @EnvironmentObject private var guide: GuideManager

    @State private var selectedTone: TonePreset = .theta6
    @State private var selectedMethod: InductionMethod = .mild
    @State private var wakeMinutes = 8

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    routeCard
                    wbtbCard
                    guideCard
                    toneCard
                    safetyCard
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Lucid Air")
            .preferredColorScheme(.dark)
        }
    }

    private var routeCard: some View {
        card {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AIRPODS SAFETY LOCK").font(.caption).foregroundStyle(.secondary)
                    Text(route.statusMessage).font(.headline)
                    Text(route.routeName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(route.isAllowedRoute ? Color.green : Color.red).frame(width: 14, height: 14)
            }
            Toggle("Strict AirPods-name check", isOn: $route.strictAirPodsOnly)
                .onChange(of: route.strictAirPodsOnly) { _, _ in route.refresh() }
            Text("When the allowed route disappears, Lucid Air stops its own alarm, tones and guidance instead of intentionally switching them to the iPhone speaker.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var wbtbCard: some View {
        card {
            Text("WBTB alarm").font(.title2.bold())
            Stepper("Sleep cycles: \(session.cycles)", value: $session.cycles, in: 3...6)
            Stepper("Cycle estimate: \(session.cycleMinutes) min", value: $session.cycleMinutes, in: 75...105, step: 5)
            Toggle("Silent background guard", isOn: $session.useBackgroundGuard)
            let total = session.cycles * session.cycleMinutes
            Text("Wake target: about \(total / 60)h \(total % 60)m after arming").font(.caption).foregroundStyle(.secondary)
            if let date = session.targetDate, session.isArmed {
                Text("Target: \(date.formatted(date: .omitted, time: .shortened))").font(.headline)
            }
            Text(session.lastEvent).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(session.isArmed ? "Cancel" : "Arm WBTB") {
                    session.isArmed ? session.cancel() : session.arm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!route.isAllowedRoute && !session.isArmed)
                Button("12-sec test") { session.armTest() }
                    .buttonStyle(.bordered)
                    .disabled(!route.isAllowedRoute)
            }
            if session.alarmFiring {
                Button("I’m awake — stop alarm") { session.stopAlarm() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }

    private var guideCard: some View {
        card {
            Text("Guided induction").font(.title2.bold())
            Picker("Method", selection: $selectedMethod) {
                ForEach(InductionMethod.allCases) { method in Text(method.rawValue).tag(method) }
            }
            .pickerStyle(.segmented)
            if selectedMethod == .mild {
                Stepper("WBTB awake time: \(wakeMinutes) min", value: $wakeMinutes, in: 3...20)
            }
            Text(guide.currentStep).font(.caption).foregroundStyle(.secondary)
            if guide.isGuiding {
                Button("Stop guide") { guide.stop() }.buttonStyle(.bordered)
            } else {
                Button("Start \(selectedMethod.rawValue) guide") {
                    if selectedMethod == .mild { guide.startMILD(wakeMinutes: wakeMinutes, toneAfterHz: 6) }
                    else { guide.startSSILD() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!route.isAllowedRoute)
            }
        }
    }

    private var toneCard: some View {
        card {
            Text("Isochronic lab").font(.title2.bold())
            Picker("Tone", selection: $selectedTone) {
                ForEach(TonePreset.allCases) { tone in Text(tone.rawValue).tag(tone) }
            }
            .pickerStyle(.menu)
            HStack {
                Button(audio.isPlaying ? "Stop" : "Play through AirPods") {
                    if audio.isPlaying { audio.stop() }
                    else if route.isAllowedRoute { audio.playIsochronic(rateHz: selectedTone.hz) }
                }
                .buttonStyle(.bordered)
                .disabled(!route.isAllowedRoute && !audio.isPlaying)
                Spacer()
                Text(audio.label).font(.caption).foregroundStyle(.secondary)
            }
            Text("Experimental only. No frequency here is presented as a proven lucid-dream trigger; WBTB plus MILD/SSILD is the main method.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var safetyCard: some View {
        card {
            Text("Before sleeping").font(.headline)
            Text("• Run the 12-second test with the phone locked.\n• Disconnect/remove the AirPods during a test and verify that the phone speaker stays quiet.\n• Keep headphone volume low enough to protect your hearing.\n• Sleep cycles are estimates, not fixed 90-minute blocks.\n• iOS may suspend apps; do not use this as a critical alarm.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }
}

@main
struct LucidAirApp: App {
    @StateObject private var route = AirPodsRouteGuard()
    @StateObject private var audio = ToneEngine()
    @StateObject private var session = SleepSessionManager()
    @StateObject private var guide = GuideManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(route)
                .environmentObject(audio)
                .environmentObject(session)
                .environmentObject(guide)
                .task {
                    route.configure()
                    session.attach(routeGuard: route, audio: audio)
                    guide.attach(routeGuard: route, audio: audio)
                }
        }
    }
}

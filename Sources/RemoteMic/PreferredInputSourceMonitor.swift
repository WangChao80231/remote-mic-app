import AppKit

final class PreferredInputSourceMonitor {
    typealias VoiceToolProvider = () -> OnboardingVoiceTool
    typealias InputSourcePreparer = (OnboardingVoiceTool) -> OnboardingInputSourceSwitchResult
    typealias CurrentInputSourceIDProvider = () -> String?
    typealias InputSourceRestorer = (String) -> OnboardingInputSourceSwitchResult
    typealias InputSourceActivationWaiter = (
        String,
        CurrentInputSourceIDProvider,
        () -> Bool
    ) -> Bool
    typealias MonitorInstaller = (@escaping (Bool) -> Void) -> Any?
    typealias MonitorRemover = (Any) -> Void
    typealias Logger = (String) -> Void

    private let voiceTool: VoiceToolProvider
    private let prepareInputSource: InputSourcePreparer
    private let currentInputSourceID: CurrentInputSourceIDProvider
    private let restoreInputSource: InputSourceRestorer
    private let waitForInputSourceActivation: InputSourceActivationWaiter
    private let installMonitor: MonitorInstaller
    private let removeMonitor: MonitorRemover
    private let logger: Logger
    private let restoreDelay: TimeInterval
    private let activationGraceDelay: TimeInterval

    private var monitor: Any?
    private var functionKeyIsPressed = false
    private var explicitVoiceSessionActivationPending = false
    private var managedInputSourceSession: ManagedInputSourceSession?
    private var pendingRestoreWorkItem: DispatchWorkItem?
    private static let activationTimeout: TimeInterval = 0.5
    private static let activationPollInterval: TimeInterval = 0.02

    var functionKeyIsPressedForDiagnostics: Bool {
        functionKeyIsPressed
    }

    private struct ManagedInputSourceSession {
        enum Owner: Hashable {
            case functionKey
            case explicitVoice
        }

        let previousInputSourceID: String?
        let targetInputSourceID: String
        var owners: Set<Owner>
        var activationPending: Bool
    }

    init(
        voiceTool: @escaping VoiceToolProvider,
        prepareInputSource: @escaping InputSourcePreparer = OnboardingInputSourceSwitcher.prepareForVoiceSession,
        currentInputSourceID: @escaping CurrentInputSourceIDProvider = OnboardingInputSourceSwitcher.currentInputSourceID,
        restoreInputSource: @escaping InputSourceRestorer = OnboardingInputSourceSwitcher.selectEnabledInputSource,
        waitForInputSourceActivation: @escaping InputSourceActivationWaiter = { target, current, shouldContinue in
            let deadline = Date().addingTimeInterval(PreferredInputSourceMonitor.activationTimeout)
            while shouldContinue(), current() != target, Date() < deadline {
                _ = RunLoop.main.run(
                    mode: .common,
                    before: Date().addingTimeInterval(PreferredInputSourceMonitor.activationPollInterval)
                )
            }
            return shouldContinue() && current() == target
        },
        installMonitor: @escaping MonitorInstaller = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                handler(event.modifierFlags.contains(.function))
            }
        },
        removeMonitor: @escaping MonitorRemover = NSEvent.removeMonitor,
        logger: @escaping Logger = AppLogger.shared.write,
        restoreDelay: TimeInterval = 2.0,
        activationGraceDelay: TimeInterval = 0.15
    ) {
        self.voiceTool = voiceTool
        self.prepareInputSource = prepareInputSource
        self.currentInputSourceID = currentInputSourceID
        self.restoreInputSource = restoreInputSource
        self.waitForInputSourceActivation = waitForInputSourceActivation
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
        self.logger = logger
        self.restoreDelay = restoreDelay
        self.activationGraceDelay = activationGraceDelay
    }

    func start() {
        guard monitor == nil else { return }
        monitor = installMonitor { [weak self] pressed in
            self?.handleFunctionKeyPressed(pressed)
        }
    }

    func stop(preservingExplicitVoiceSession: Bool = false) {
        if !preservingExplicitVoiceSession {
            explicitVoiceSessionActivationPending = false
        }
        cancelPendingRestore()
        finishManagedInputSourceSession(
            reason: "monitor_stop",
            owner: preservingExplicitVoiceSession ? .functionKey : nil
        )
        if let monitor {
            removeMonitor(monitor)
            self.monitor = nil
        }
        functionKeyIsPressed = false
    }

    func handleFunctionKeyPressed(_ pressed: Bool) {
        guard pressed != functionKeyIsPressed else { return }
        functionKeyIsPressed = pressed
        if !pressed {
            let selectedVoiceTool = voiceTool()
            if selectedVoiceTool.preferredInputSourceID != nil || managedInputSourceSession != nil {
                logger(
                    "VOICE INPUT function_key edge=up tool=\(selectedVoiceTool.rawValue)"
                )
            }
            finishManagedInputSourceSession(
                reason: "function_key_up",
                owner: .functionKey
            )
            return
        }

        let selectedVoiceTool = voiceTool()
        if selectedVoiceTool.preferredInputSourceID != nil || managedInputSourceSession != nil {
            logger(
                "VOICE INPUT function_key edge=down tool=\(selectedVoiceTool.rawValue)"
            )
        }
        beginVoiceSession(reason: "function_key_down", owner: .functionKey)
    }

    /// Starts the input-source session for a software-emitted voice key.
    /// Command keys do not produce the Fn `flagsChanged` event that the legacy
    /// monitor observes, so their lifecycle is driven explicitly by the voice
    /// session instead of by every ordinary Command press on the Mac keyboard.
    @discardableResult
    func beginVoiceSession() -> Bool {
        explicitVoiceSessionActivationPending = true
        defer { explicitVoiceSessionActivationPending = false }
        return beginVoiceSession(
            reason: "voice_session_start",
            owner: .explicitVoice,
            activationShouldContinue: { [weak self] in
                self?.explicitVoiceSessionActivationPending == true
            }
        )
    }

    /// Ends an input-source session previously started for a voice key.
    func endVoiceSession() {
        explicitVoiceSessionActivationPending = false
        finishManagedInputSourceSession(
            reason: "voice_session_end",
            owner: .explicitVoice
        )
    }

    @discardableResult
    private func beginVoiceSession(
        reason: String,
        owner: ManagedInputSourceSession.Owner,
        activationShouldContinue: () -> Bool = { true }
    ) -> Bool {
        let selectedVoiceTool = voiceTool()
        if selectedVoiceTool.preferredInputSourceID != nil || managedInputSourceSession != nil {
            logger(
                "VOICE INPUT session edge=down reason=\(reason) " +
                    "tool=\(selectedVoiceTool.rawValue)"
            )
        }
        guard let targetInputSourceID = selectedVoiceTool.preferredInputSourceID else { return true }
        if var session = managedInputSourceSession {
            cancelPendingRestore()
            guard session.targetInputSourceID == targetInputSourceID else {
                logger("VOICE INPUT session_rejected reason=target_changed")
                return false
            }
            if session.activationPending {
                let currentSourceID = currentInputSourceID()
                guard currentSourceID == session.targetInputSourceID ||
                      currentSourceID == session.previousInputSourceID
                else {
                    logger("VOICE INPUT session_rejected reason=source_changed")
                    return false
                }
                session.owners.insert(owner)
                managedInputSourceSession = session
                return true
            }
            if currentInputSourceID() == targetInputSourceID {
                session.owners.insert(owner)
                managedInputSourceSession = session
                return true
            }
            guard owner == .explicitVoice else {
                logger("VOICE INPUT session_rejected reason=source_changed")
                return false
            }
            session.owners.insert(owner)
            session.activationPending = true
            managedInputSourceSession = session
            return completeExplicitActivation(
                targetInputSourceID: targetInputSourceID,
                activationShouldContinue: activationShouldContinue,
                selectedVoiceTool: selectedVoiceTool
            )
        }

        let previousInputSourceID = currentInputSourceID()
        if previousInputSourceID == targetInputSourceID {
            logger(
                "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) result=selected managed=false"
            )
            return true
        }

        let result = prepareInputSource(selectedVoiceTool)
        logger(
            "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) result=\(result.rawValue) " +
                "managed=\(result == .selected && previousInputSourceID != nil)"
        )
        guard result == .selected else { return false }
        managedInputSourceSession = ManagedInputSourceSession(
            previousInputSourceID: previousInputSourceID,
            targetInputSourceID: targetInputSourceID,
            owners: [owner],
            activationPending: owner == .explicitVoice
        )
        if owner == .explicitVoice {
            return completeExplicitActivation(
                targetInputSourceID: targetInputSourceID,
                activationShouldContinue: activationShouldContinue,
                selectedVoiceTool: selectedVoiceTool
            )
        }
        return true
    }

    private func completeExplicitActivation(
        targetInputSourceID: String,
        activationShouldContinue: () -> Bool,
        selectedVoiceTool: OnboardingVoiceTool
    ) -> Bool {
        guard waitForInputSourceActivation(
            targetInputSourceID,
            currentInputSourceID,
            activationShouldContinue
        ) else {
            let activationResult = activationShouldContinue()
                ? "activation_timeout"
                : "activation_cancelled"
            logger(
                "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) " +
                    "result=\(activationResult)"
            )
            if var session = managedInputSourceSession {
                session.activationPending = false
                managedInputSourceSession = session
            }
            finishManagedInputSourceSession(
                reason: activationResult,
                owner: .explicitVoice
            )
            return false
        }
        guard var session = managedInputSourceSession,
              session.owners.contains(.explicitVoice),
              session.targetInputSourceID == targetInputSourceID
        else { return false }
        session.activationPending = false
        managedInputSourceSession = session
        // 输入源已切换，但输入法在前台应用完成“接管输入框”还需片刻；
        // 立即注入触发键会丢（微信输入法实测），宽限后再让调用方注入。
        if activationGraceDelay > 0, activationShouldContinue() {
            let graceDeadline = Date().addingTimeInterval(activationGraceDelay)
            while Date() < graceDeadline, activationShouldContinue() {
                _ = RunLoop.main.run(
                    mode: .common,
                    before: min(
                        graceDeadline,
                        Date().addingTimeInterval(Self.activationPollInterval)
                    )
                )
            }
        }
        return true
    }

    private func finishManagedInputSourceSession(
        reason: String,
        owner: ManagedInputSourceSession.Owner?
    ) {
        guard var session = managedInputSourceSession else { return }
        if let owner {
            session.owners.remove(owner)
            guard session.owners.isEmpty else {
                managedInputSourceSession = session
                return
            }
            // 松开语音键时延迟切回：给输入法留出“停录→等最终文字→提交”的时间。
            // 立即切回会打断提交，识别文字卡在输入法语音气泡上。
            // 延迟期间再按语音键会复用会话（beginVoiceSession 取消本次延迟切回）。
            if restoreDelay > 0,
               (owner == .explicitVoice && reason == "voice_session_end")
                || (owner == .functionKey && reason == "function_key_up") {
                scheduleDelayedRestore(session: session, reason: reason)
                return
            }
        }
        managedInputSourceSession = nil
        restoreSessionNow(session: session, reason: reason)
    }

    private func scheduleDelayedRestore(
        session: ManagedInputSourceSession,
        reason: String
    ) {
        pendingRestoreWorkItem?.cancel()
        managedInputSourceSession = session
        logger(
            "VOICE INPUT source_restore_delayed delay=\(restoreDelay) reason=\(reason)"
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestoreWorkItem = nil
            guard let pending = self.managedInputSourceSession,
                  pending.targetInputSourceID == session.targetInputSourceID
            else { return }
            self.managedInputSourceSession = nil
            self.restoreSessionNow(session: session, reason: "\(reason)_delayed")
        }
        pendingRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + restoreDelay,
            execute: workItem
        )
    }

    private func cancelPendingRestore() {
        pendingRestoreWorkItem?.cancel()
        pendingRestoreWorkItem = nil
    }

    private func restoreSessionNow(
        session: ManagedInputSourceSession,
        reason: String
    ) {
        guard let previousInputSourceID = session.previousInputSourceID else { return }
        let currentSourceID = currentInputSourceID()
        guard currentSourceID == session.targetInputSourceID ||
              currentSourceID == previousInputSourceID
        else {
            logger(
                "VOICE INPUT source_restore skipped reason=user_changed session_reason=\(reason)"
            )
            return
        }

        let result = restoreInputSource(previousInputSourceID)
        logger(
            "VOICE INPUT source_restore result=\(result.rawValue) reason=\(reason)"
        )
    }

    deinit {
        stop()
    }
}

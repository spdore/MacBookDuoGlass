import AppKit
import CoreGraphics
import Foundation

final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let sensor = LidAngleSensor()
    private let capture = ScreenCaptureService()

    private var statusItem: NSStatusItem!
    private var overlay: OverlayWindow?
    private var currentEffect = EffectModel.state(angle: 0, isValid: false)
    private var lastFrame: CVPixelBuffer?
    private var lastAngleSample: AngleSample?
    private var isEnabled = true
    private var hahaMirrorModeEnabled = false
    private var adaptiveAngleEnabled = false
    private var adaptiveAngleTimer: Timer?
    private var adaptiveAngleTracker = AdaptiveAngleTracker()
    private var manualThresholdBeforeAdaptive: Double?
    private var captureDemandActive = false
    private var isCaptureReady = false
    private var captureError: String?
    private var captureRetrySuppressed = false
    private var permissionPollTimer: Timer?
    private var permissionRequestActive = false
    private weak var thresholdControl: ThresholdMenuView?
    private weak var curveControl: CurveMenuView?
    private weak var enabledControl: ModeToggleMenuView?
    private weak var hahaMirrorControl: ModeToggleMenuView?
    private weak var adaptiveAngleControl: ModeToggleMenuView?
    private let frameLock = NSLock()
    private var pendingFrame: CVPixelBuffer?
    private var frameDeliveryScheduled = false
    private var frameDeliverySession = 0
    private var captureSessionID = 0
    private var lifecycleRestartScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installLifecycleObservers()
        startSensor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        stopAdaptiveAngleObservation()
        stopCaptureForInactiveState()
        sensor.stop()
        hideOverlay()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Duo"
        statusItem.button?.toolTip = "MacBook Duo Glass 开合角度磨砂"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let enabledControl = ModeToggleMenuView(
            title: "启用效果",
            isOn: isEnabled,
            toolTip: "控制屏幕效果总开关")
        enabledControl.onChange = { [weak self] isOn in
            self?.setEnabled(isOn)
        }
        let enabledItem = NSMenuItem()
        enabledItem.view = enabledControl
        menu.addItem(enabledItem)
        self.enabledControl = enabledControl

        let hahaMirrorControl = ModeToggleMenuView(
            title: "哈哈镜模式",
            isOn: hahaMirrorModeEnabled,
            toolTip: "只改变折叠透视角度，不使用模糊、磨砂、反射和色散")
        hahaMirrorControl.onChange = { [weak self] isOn in
            self?.setHahaMirrorMode(isOn)
        }
        let hahaMirrorItem = NSMenuItem()
        hahaMirrorItem.view = hahaMirrorControl
        menu.addItem(hahaMirrorItem)
        self.hahaMirrorControl = hahaMirrorControl

        let adaptiveAngleControl = ModeToggleMenuView(
            title: "自适应角度",
            isOn: adaptiveAngleEnabled,
            toolTip: "固定角度超过 3 秒后，以当前角度减 3°作为启动阈值（最低 75°）")
        adaptiveAngleControl.onChange = { [weak self] isOn in
            self?.setAdaptiveAngle(isOn)
        }
        let adaptiveAngleItem = NSMenuItem()
        adaptiveAngleItem.view = adaptiveAngleControl
        menu.addItem(adaptiveAngleItem)
        self.adaptiveAngleControl = adaptiveAngleControl
        menu.addItem(NSMenuItem.separator())
        let thresholdControl = ThresholdMenuView(threshold: EffectModel.clearThreshold)
        thresholdControl.onChange = { [weak self] threshold in
            self?.setThreshold(threshold)
        }
        let thresholdItem = NSMenuItem()
        thresholdItem.view = thresholdControl
        menu.addItem(thresholdItem)
        self.thresholdControl = thresholdControl
        let curveControl = CurveMenuView(curve: EffectModel.intensityCurve)
        curveControl.onChange = { [weak self] curve in
            self?.setIntensityCurve(curve)
        }
        let curveItem = NSMenuItem()
        curveItem.view = curveControl
        menu.addItem(curveItem)
        self.curveControl = curveControl
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "显示诊断", action: #selector(showDiagnostics), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新检查屏幕录制权限", action: #selector(recheckPermission), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 MacBook Duo Glass", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func startSensor() {
        sensor.start { [weak self] sample in
            self?.receive(sample)
        }
    }

    private func requestOrStartCapture() {
        guard captureDemandActive,
              !captureRetrySuppressed,
              !capture.isRunning,
              !capture.isStarting,
              permissionPollTimer == nil,
              !permissionRequestActive else { return }
        guard CGPreflightScreenCaptureAccess() else {
            permissionRequestActive = true
            let requested = CGRequestScreenCaptureAccess()
            showPermissionNotice(requested: requested)
            beginPermissionPolling()
            return
        }
        permissionRequestActive = false
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        startCapture()
    }

    private func beginPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.captureDemandActive else {
                timer.invalidate()
                self.permissionPollTimer = nil
                return
            }
            if CGPreflightScreenCaptureAccess() {
                timer.invalidate()
                self.permissionPollTimer = nil
                self.permissionRequestActive = false
                self.startCapture()
            }
        }
    }

    private func showPermissionNotice(requested: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = requested
            ? "请在系统设置中允许 MacBook Duo Glass 录制屏幕。画面只在本机内存中用于实时渲染，不会保存或上传。授权后返回应用，效果会自动继续。"
            : "请在“系统设置 → 隐私与安全性 → 屏幕录制”中允许此应用，然后点击菜单栏中的“重新检查屏幕录制权限”。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func startCapture() {
        guard captureDemandActive, !capture.isRunning, !capture.isStarting else { return }
        // Register a transparent window before discovering our capture exclusion.
        if overlay == nil, let screen = builtInScreen() {
            overlay = OverlayWindow(screen: screen)
        }
        guard let overlay else { return }
        let session = beginCaptureSession()
        lastFrame = nil
        isCaptureReady = false
        captureError = nil
        overlay.alphaValue = 0
        overlay.orderFrontRegardless()
        capture.start(
            frameHandler: { [weak self] pixelBuffer in
                self?.receiveFrame(pixelBuffer, session: session)
            },
            stateHandler: { [weak self] result in
                guard let self else { return }
                guard self.isCurrentCaptureSession(session), self.captureDemandActive else {
                    return
                }
                switch result {
                case .success:
                    self.isCaptureReady = true
                    self.captureError = nil
                    self.updateOverlayIfNeeded()
                case .failure(let error):
                    self.isCaptureReady = false
                    self.captureError = error.localizedDescription
                    self.captureRetrySuppressed = true
                    NSLog("Duo capture failed: %@", error.localizedDescription)
                    self.hideOverlay()
                    self.presentErrorOnce(error)
                }
            }
        )
    }

    private func stopCaptureForInactiveState() {
        let hadCaptureState = captureDemandActive || capture.isRunning || capture.isStarting || isCaptureReady || lastFrame != nil || permissionPollTimer != nil
        captureDemandActive = false
        permissionRequestActive = false
        captureRetrySuppressed = false
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        guard hadCaptureState else {
            hideOverlay()
            return
        }
        invalidateCaptureSession()
        capture.stop()
        isCaptureReady = false
        captureError = nil
        lastFrame = nil
        overlay?.renderer.releaseFrameResources()
        hideOverlay()
    }

    private func beginCaptureSession() -> Int {
        frameLock.lock()
        captureSessionID &+= 1
        let session = captureSessionID
        pendingFrame = nil
        frameDeliveryScheduled = false
        frameDeliverySession = 0
        frameLock.unlock()
        return session
    }

    private func invalidateCaptureSession() {
        frameLock.lock()
        captureSessionID &+= 1
        pendingFrame = nil
        frameDeliveryScheduled = false
        frameDeliverySession = 0
        frameLock.unlock()
    }

    private func isCurrentCaptureSession(_ session: Int) -> Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return captureSessionID == session
    }

    private func receive(_ sample: AngleSample) {
        lastAngleSample = sample
        guard sample.isValid else {
            adaptiveAngleTracker.reset()
            currentEffect = EffectModel.state(angle: 0, isValid: false)
            stopCaptureForInactiveState()
            return
        }

        if adaptiveAngleEnabled {
            adaptiveAngleTracker.accept(sample)
            evaluateAdaptiveAngle(at: sample.timestamp)
        }
        currentEffect = EffectModel.state(angle: sample.degrees,
                                          projectionOnly: hahaMirrorModeEnabled)
        updateCaptureDemand()
    }

    private func updateCaptureDemand() {
        let shouldCapture = isEnabled && currentEffect.isValid && !currentEffect.isClear
        if shouldCapture {
            if !captureDemandActive {
                captureDemandActive = true
                permissionRequestActive = false
                captureRetrySuppressed = false
            }
            requestOrStartCapture()
            updateOverlayIfNeeded()
        } else if captureDemandActive || capture.isRunning || capture.isStarting ||
                    isCaptureReady || lastFrame != nil || permissionPollTimer != nil {
            stopCaptureForInactiveState()
        }
    }

    private func receiveFrame(_ pixelBuffer: CVPixelBuffer, session: Int) {
        // Coalesce capture callbacks. A slow render must never make the
        // ScreenCaptureKit queue back up or block the AppKit event loop.
        frameLock.lock()
        guard captureSessionID == session else {
            frameLock.unlock()
            return
        }
        pendingFrame = pixelBuffer
        if frameDeliveryScheduled {
            frameLock.unlock()
            return
        }
        frameDeliveryScheduled = true
        frameDeliverySession = session
        frameLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            guard self.frameDeliveryScheduled,
                  self.frameDeliverySession == session,
                  self.captureSessionID == session else {
                self.frameLock.unlock()
                return
            }
            let newestFrame = self.pendingFrame
            self.pendingFrame = nil
            self.frameDeliveryScheduled = false
            self.frameDeliverySession = 0
            self.frameLock.unlock()

            guard let newestFrame else { return }
            self.lastFrame = newestFrame
            self.overlay?.renderer.prepare(newestFrame)
            self.updateOverlayIfNeeded()
        }
    }

    private func updateOverlayIfNeeded() {
        guard isEnabled,
              isCaptureReady,
              currentEffect.isValid,
              !currentEffect.isClear,
              let frame = lastFrame,
              let screen = builtInScreen() else {
            hideOverlay()
            return
        }

        if let overlay {
            overlay.update(screen: screen)
            overlay.updateFrame(frame)
            overlay.updateEffect(currentEffect)
            if overlay.renderer.isPaused || !overlay.isVisible {
                overlay.alphaValue = 0
            }
            overlay.renderer.isPaused = false
            if !overlay.isVisible { overlay.orderFrontRegardless() }

        }
    }

    private func hideOverlay() {
        if overlay?.renderer.isPaused == false {
            overlay?.renderer.isPaused = true
            overlay?.renderer.resetAngleTransition()
        }
        overlay?.alphaValue = 0
        if overlay?.isVisible == true { overlay?.orderOut(nil) }
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLifecycleRestart()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopCaptureForInactiveState()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopCaptureForInactiveState()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLifecycleRestart()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLifecycleRestart()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLifecycleRestart()
        }
    }

    private func scheduleLifecycleRestart() {
        guard !lifecycleRestartScheduled else { return }
        lifecycleRestartScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lifecycleRestartScheduled = false
            self.lastFrame = nil
            self.restartForDisplayChange()
        }
    }

    private func restartForDisplayChange() {
        stopCaptureForInactiveState()
        updateCaptureDemand()
    }

    private func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        updateCaptureDemand()
        rebuildMenu()
    }

    private func setHahaMirrorMode(_ enabled: Bool) {
        guard hahaMirrorModeEnabled != enabled else { return }
        hahaMirrorModeEnabled = enabled
        currentEffect = EffectModel.state(
            angle: currentEffect.angle,
            isValid: currentEffect.isValid,
            projectionOnly: hahaMirrorModeEnabled)
        updateCaptureDemand()
        rebuildMenu()
    }

    private func setAdaptiveAngle(_ enabled: Bool) {
        guard adaptiveAngleEnabled != enabled else { return }
        adaptiveAngleEnabled = enabled
        if adaptiveAngleEnabled {
            manualThresholdBeforeAdaptive = EffectModel.clearThreshold
            adaptiveAngleTracker.reset()
            if let lastAngleSample, lastAngleSample.isValid {
                // Start the three-second interval when the user enables the
                // option, even if the sensor has not changed since then.
                adaptiveAngleTracker.accept(.init(
                    degrees: lastAngleSample.degrees,
                    rawValue: lastAngleSample.rawValue,
                    timestamp: CACurrentMediaTime(),
                    isValid: true
                ))
            }
            startAdaptiveAngleObservation()
        } else {
            stopAdaptiveAngleObservation()
            if let manualThreshold = manualThresholdBeforeAdaptive {
                EffectModel.clearThreshold = manualThreshold
                thresholdControl?.setThreshold(manualThreshold)
                if currentEffect.isValid {
                    currentEffect = EffectModel.state(
                        angle: currentEffect.angle,
                        projectionOnly: hahaMirrorModeEnabled)
                    updateCaptureDemand()
                }
            }
            manualThresholdBeforeAdaptive = nil
        }
        rebuildMenu()
    }

    @objc private func recheckPermission() {
        captureRetrySuppressed = false
        updateCaptureDemand()
    }

    private func setThreshold(_ threshold: Double) {
        EffectModel.clearThreshold = threshold
        if adaptiveAngleEnabled {
            // A manual slider change remains the value restored when the
            // adaptive mode is turned off.
            manualThresholdBeforeAdaptive = threshold
        }
        thresholdControl?.setThreshold(EffectModel.clearThreshold)
        guard currentEffect.isValid else { return }
        currentEffect = EffectModel.state(
            angle: currentEffect.angle,
            projectionOnly: hahaMirrorModeEnabled)
        updateCaptureDemand()
    }

    private func setIntensityCurve(_ curve: Double) {
        EffectModel.intensityCurve = curve
        curveControl?.setCurve(EffectModel.intensityCurve)
        guard currentEffect.isValid else { return }
        currentEffect = EffectModel.state(
            angle: currentEffect.angle,
            projectionOnly: hahaMirrorModeEnabled)
        updateCaptureDemand()
    }

    private func startAdaptiveAngleObservation() {
        adaptiveAngleTimer?.invalidate()
        adaptiveAngleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.evaluateAdaptiveAngle(at: CACurrentMediaTime())
        }
    }

    private func stopAdaptiveAngleObservation() {
        adaptiveAngleTimer?.invalidate()
        adaptiveAngleTimer = nil
        adaptiveAngleTracker.reset()
    }

    private func evaluateAdaptiveAngle(at time: CFTimeInterval) {
        guard adaptiveAngleEnabled,
              currentEffect.isValid,
              let threshold = adaptiveAngleTracker.thresholdIfReady(at: time) else { return }
        guard abs(EffectModel.clearThreshold - threshold) > 0.01 else {
            thresholdControl?.setThreshold(threshold)
            return
        }
        EffectModel.clearThreshold = threshold
        thresholdControl?.setThreshold(threshold)
        currentEffect = EffectModel.state(
            angle: currentEffect.angle,
            projectionOnly: hahaMirrorModeEnabled)
        updateCaptureDemand()
    }

    @objc private func showDiagnostics() {
        let screen = builtInScreen()
        let screenText = screen == nil ? "未找到" : "已找到"
        let thresholdText = String(format: "%.0f°", EffectModel.clearThreshold)
        let effectText = currentEffect.isClear ? "清晰（≥\(thresholdText)）" : currentEffect.isValid ? String(format: "效果中（%.1f°，强度 %.1f%%）", currentEffect.angle, currentEffect.intensity * 100) : "角度无效"
        let captureText = isCaptureReady ? "已就绪（已排除自身进程）" : captureDemandActive ? (captureError ?? "按需启动中") : "未进入阈值（未启动）"
        let adaptiveText = adaptiveAngleEnabled ? "\n自适应角度：已开启（静止 3 秒，最低 75°）" : ""
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "MacBook Duo Glass 诊断"
        alert.informativeText = "内置显示器：\(screenText)\n屏幕采集：\(captureText)\n当前状态：\(effectText)\(adaptiveText)\n\n屏幕画面只用于内存中的实时渲染。"
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    private func presentErrorOnce(_ error: Error) {
        // Keep failure handling quiet in the sensor's 60 Hz path. A menu
        // diagnostic remains available, and a single capture failure is shown.
        guard NSApp.isActive else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MacBook Duo Glass 已暂停"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

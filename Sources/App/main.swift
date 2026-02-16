import Cocoa
import Speech
import AVFoundation

@MainActor
final class StatusHUD {
    private let panel: NSPanel
    private let containerView: NSVisualEffectView
    private let statusLabel: NSTextField
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 8
    private let minWidth: CGFloat = 180
    private let maxWidth: CGFloat = 460

    init(initialStatus: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        containerView = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        containerView.autoresizingMask = [.width, .height]
        containerView.material = .hudWindow
        containerView.state = .active
        containerView.blendingMode = .withinWindow
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 10
        panel.contentView = containerView

        statusLabel = NSTextField(labelWithString: initialStatus)
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: horizontalPadding),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -horizontalPadding),
            statusLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: verticalPadding),
            statusLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -verticalPadding)
        ])

        update(status: initialStatus)
    }

    func update(status: String) {
        statusLabel.stringValue = status
        resizeAndReposition(for: status)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func resizeAndReposition(for status: String) {
        let textWidth = ceil((status as NSString).size(withAttributes: [.font: statusLabel.font as Any]).width)
        let width = min(max(textWidth + horizontalPadding * 2, minWidth), maxWidth)
        let font = statusLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .semibold)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = lineHeight + verticalPadding * 2

        let targetScreen = screenForCurrentContext()
        let visible = targetScreen.visibleFrame
        let originX = visible.midX - width / 2
        let originY = visible.maxY - height - 10
        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
    }

    private func screenForCurrentContext() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hoveredScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hoveredScreen
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private struct ASRProviderPresentation {
        let displayName: String
        let badge: String
    }

    private var statusItem: NSStatusItem!
    private var statusHUD: StatusHUD!
    private var currentASRProviderStatusItem: NSMenuItem?
    private var voiceInputManager: VoiceInputManager!
    private var hotKeyManager: HotKeyManager!
    private var lastInputTargetApplication: NSRunningApplication?
    private var hotKeyInstructionMenuItem: NSMenuItem?
    private var currentHotKeyMenuItem: NSMenuItem?

    private var hotKeyCapturePanel: NSPanel?
    private var hotKeyCaptureStatusLabel: NSTextField?
    private var hotKeyCaptureMonitor: Any?
    private var hotKeyCapturePressedKeyCodes = Set<UInt16>()
    private var hotKeyCapturedKeyCodes: [UInt16] = HotKeyManager.defaultShortcutKeyCodes

    private var asrProviderMenuItems: [String: NSMenuItem] = [:]
    private var optimizeProviderMenuItems: [String: NSMenuItem] = [:]
    private var tencentCredentialStatusItem: NSMenuItem?
    private var statusHUDAutoHideWorkItem: DispatchWorkItem?
    private let asrProviderPresentations: [String: ASRProviderPresentation] = [
        "qwen3_local": ASRProviderPresentation(displayName: "Qwen3 本地模型", badge: "Q3"),
        "apple_speech": ASRProviderPresentation(displayName: "Apple Speech", badge: "SP"),
        "tencent_cloud": ASRProviderPresentation(displayName: "腾讯云 ASR", badge: "TC")
    ]

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("App launched!")  // 调试用

        // 激活应用
        NSApp.activate(ignoringOtherApps: true)

        statusHUD = StatusHUD(initialStatus: "就绪")
        setupMenuBar()
        setupVoiceInput()
        setupHotKey()

        // 不再自动请求权限，用户需要手动在系统设置中授权
        print("请在系统设置中授予权限:")
        print("1. 系统设置 → 隐私与安全性 → 辅助功能 → 添加 SmartVoiceIn")
        print("2. 系统设置 → 隐私与安全性 → 麦克风 → 添加 SmartVoiceIn")
        print("3. 系统设置 → 隐私与安全性 → 语音识别 → 添加 SmartVoiceIn")
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initialASRRawValue = VoiceInputManager.currentASRProviderRawValue()
        let initialASRPresentation = asrProviderPresentations[initialASRRawValue]

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "SmartVoiceIn")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = initialASRPresentation?.badge ?? "ASR"
            button.toolTip = "SmartVoiceIn - 当前引擎: \(initialASRPresentation?.displayName ?? "未知引擎")"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "状态: 就绪", action: nil, keyEquivalent: ""))
        currentASRProviderStatusItem = NSMenuItem(
            title: "当前引擎: \(initialASRPresentation?.displayName ?? "未知引擎")",
            action: nil,
            keyEquivalent: ""
        )
        if let currentASRProviderStatusItem {
            menu.addItem(currentASRProviderStatusItem)
        }
        menu.addItem(NSMenuItem.separator())
        hotKeyInstructionMenuItem = NSMenuItem(
            title: "按 \(HotKeyManager.formatShortcutDisplayName(keyCodes: HotKeyManager.defaultShortcutKeyCodes)) 开始/停止录音",
            action: nil,
            keyEquivalent: ""
        )
        if let hotKeyInstructionMenuItem {
            menu.addItem(hotKeyInstructionMenuItem)
        }
        currentHotKeyMenuItem = NSMenuItem(
            title: "当前快捷键: \(HotKeyManager.formatShortcutDisplayName(keyCodes: HotKeyManager.defaultShortcutKeyCodes))",
            action: nil,
            keyEquivalent: ""
        )
        if let currentHotKeyMenuItem {
            menu.addItem(currentHotKeyMenuItem)
        }
        let hotKeyConfigItem = NSMenuItem(title: "设置快捷键...", action: #selector(openHotKeyConfiguration), keyEquivalent: "")
        hotKeyConfigItem.target = self
        menu.addItem(hotKeyConfigItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeASRProviderMenuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeTextOptimizeProviderMenuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setupVoiceInput() {
        voiceInputManager = VoiceInputManager(
            onResult: { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        self?.insertText(text)
                        let providerName = self?.currentASRProviderDisplayName() ?? "未知引擎"
                        self?.updateStatus("识别成功(\(providerName)): \(text)", autoHideAfter: 5)
                    case .failure(let error):
                        let providerName = self?.currentASRProviderDisplayName() ?? "未知引擎"
                        self?.updateStatus("识别失败(\(providerName)): \(error.localizedDescription)")
                    }
                }
            },
            onStatusUpdate: { [weak self] status in
                DispatchQueue.main.async {
                    self?.updateStatus(status)
                }
            }
        )
        refreshASRProviderUI()
        refreshOptimizeProviderMenuState()
        refreshTencentCredentialStatusUI()
    }

    private func makeASRProviderMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "语音识别引擎", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let qwen3Item = NSMenuItem(title: "Qwen3 本地模型", action: #selector(selectQwen3Provider), keyEquivalent: "")
        qwen3Item.target = self
        asrProviderMenuItems["qwen3_local"] = qwen3Item
        submenu.addItem(qwen3Item)

        let appleSpeechItem = NSMenuItem(title: "Apple Speech", action: #selector(selectAppleSpeechProvider), keyEquivalent: "")
        appleSpeechItem.target = self
        asrProviderMenuItems["apple_speech"] = appleSpeechItem
        submenu.addItem(appleSpeechItem)

        let tencentCloudItem = NSMenuItem(title: "腾讯云 ASR", action: #selector(selectTencentCloudProvider), keyEquivalent: "")
        tencentCloudItem.target = self
        asrProviderMenuItems["tencent_cloud"] = tencentCloudItem
        submenu.addItem(tencentCloudItem)

        parent.submenu = submenu
        return parent
    }

    private func refreshASRProviderUI() {
        let selected = voiceInputManager?.currentASRProviderRawValue()
        let hasTencentCredentials = voiceInputManager?.hasTencentCredentialsConfigured() ?? false
        for (rawValue, item) in asrProviderMenuItems {
            item.state = (rawValue == selected) ? .on : .off
            if rawValue == "tencent_cloud" {
                item.isEnabled = hasTencentCredentials
                item.toolTip = hasTencentCredentials ? nil : "请先配置腾讯云密钥"
            }
        }

        let displayName = selected.flatMap { asrProviderPresentations[$0] }?.displayName ?? "未知引擎"
        let badge = selected.flatMap { asrProviderPresentations[$0] }?.badge ?? "ASR"
        currentASRProviderStatusItem?.title = "当前引擎: \(displayName)"

        if let button = statusItem.button {
            button.title = badge
            button.toolTip = "SmartVoiceIn - 当前引擎: \(displayName)"
        }
    }

    @objc private func selectQwen3Provider() {
        selectASRProvider(rawValue: "qwen3_local", displayName: "Qwen3 本地模型")
    }

    @objc private func selectAppleSpeechProvider() {
        selectASRProvider(rawValue: "apple_speech", displayName: "Apple Speech")
    }

    @objc private func selectTencentCloudProvider() {
        selectASRProvider(rawValue: "tencent_cloud", displayName: "腾讯云 ASR")
    }

    private func selectASRProvider(rawValue: String, displayName: String) {
        let currentRawValue = voiceInputManager.currentASRProviderRawValue()
        if currentRawValue == rawValue {
            refreshASRProviderUI()
            updateStatus("语音识别引擎未变化: \(displayName)")
            return
        }

        if rawValue == "tencent_cloud", !voiceInputManager.hasTencentCredentialsConfigured() {
            updateStatus("切换失败: 请先在“文本优化模型 -> 设置腾讯云密钥...”中配置 SecretId/SecretKey")
            refreshASRProviderUI()
            return
        }

        guard voiceInputManager.updateASRProvider(rawValue: rawValue) else {
            updateStatus("切换失败: 不支持的语音识别引擎(\(rawValue))")
            return
        }

        refreshASRProviderUI()
        if let warning = switchWarningForASRProvider(rawValue: rawValue) {
            updateStatus("已切换为 \(displayName)，\(warning)")
            return
        }
        updateStatus("已切换为 \(displayName)")
    }

    private func makeTextOptimizeProviderMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "文本优化模型", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        optimizeProviderMenuItems.removeAll()
        for option in LLMTextOptimizer.providerOptions {
            let item = NSMenuItem(title: option.displayName, action: #selector(selectTextOptimizeProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            optimizeProviderMenuItems[option.rawValue] = item
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        tencentCredentialStatusItem = NSMenuItem(title: "腾讯云密钥: 未配置", action: nil, keyEquivalent: "")
        tencentCredentialStatusItem?.isEnabled = false
        if let tencentCredentialStatusItem {
            submenu.addItem(tencentCredentialStatusItem)
        }

        let configItem = NSMenuItem(title: "设置腾讯云密钥...", action: #selector(openTencentCredentialConfiguration), keyEquivalent: "")
        configItem.target = self
        submenu.addItem(configItem)

        parent.submenu = submenu
        return parent
    }

    private func refreshOptimizeProviderMenuState() {
        let selected = voiceInputManager?.currentTextOptimizeProviderRawValue()
        for (rawValue, item) in optimizeProviderMenuItems {
            item.state = (rawValue == selected) ? .on : .off
        }
    }

    private func refreshTencentCredentialStatusUI() {
        let configured = voiceInputManager?.hasTencentCredentialsConfigured() ?? false
        tencentCredentialStatusItem?.title = configured ? "腾讯云密钥: 已配置" : "腾讯云密钥: 未配置"
        refreshASRProviderUI()
    }

    @objc private func selectTextOptimizeProvider(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else {
            updateStatus("切换失败: 无效的文本优化模型")
            return
        }
        let displayName = LLMTextOptimizer.displayName(for: rawValue) ?? rawValue
        selectProvider(rawValue: rawValue, displayName: displayName)
    }

    private func selectProvider(rawValue: String, displayName: String) {
        let currentRawValue = voiceInputManager.currentTextOptimizeProviderRawValue()
        if currentRawValue == rawValue {
            refreshOptimizeProviderMenuState()
            updateStatus("文本优化模型未变化: \(displayName)")
            return
        }

        guard voiceInputManager.updateTextOptimizeProvider(rawValue: rawValue) else {
            updateStatus("切换失败: 不支持的模型提供方")
            return
        }
        refreshOptimizeProviderMenuState()
        updateStatus("文本优化模型: \(displayName)")
    }

    @objc private func openTencentCredentialConfiguration() {
        guard voiceInputManager != nil else {
            updateStatus("配置未就绪，请稍后重试")
            return
        }
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        let existing = voiceInputManager.currentTencentCredentialValues()

        let alert = NSAlert()
        alert.messageText = "腾讯云密钥设置"
        alert.informativeText = "输入 SecretId 与 SecretKey，保存后将持久化到本地并立即应用。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存并应用")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 128))
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let secretIdLabel = NSTextField(labelWithString: "SecretId")
        secretIdLabel.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(secretIdLabel)

        let secretIdField = NSTextField(string: existing?.secretId ?? "")
        secretIdField.placeholderString = "AKIDxxxxxxxxxxxxxxxx"
        secretIdField.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(secretIdField)

        let secretKeyLabel = NSTextField(labelWithString: "SecretKey")
        secretKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(secretKeyLabel)

        let secretKeyField = NSSecureTextField(string: existing?.secretKey ?? "")
        secretKeyField.placeholderString = "xxxxxxxxxxxxxxxx"
        secretKeyField.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(secretKeyField)

        NSLayoutConstraint.activate([
            secretIdLabel.topAnchor.constraint(equalTo: accessory.topAnchor),
            secretIdLabel.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            secretIdLabel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            secretIdField.topAnchor.constraint(equalTo: secretIdLabel.bottomAnchor, constant: 6),
            secretIdField.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            secretIdField.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            secretKeyLabel.topAnchor.constraint(equalTo: secretIdField.bottomAnchor, constant: 10),
            secretKeyLabel.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            secretKeyLabel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            secretKeyField.topAnchor.constraint(equalTo: secretKeyLabel.bottomAnchor, constant: 6),
            secretKeyField.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            secretKeyField.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            secretKeyField.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else {
            updateStatus("已取消腾讯云密钥更新")
            return
        }

        let secretId = secretIdField.stringValue
        let secretKey = secretKeyField.stringValue
        guard voiceInputManager.updateTencentCredentials(secretId: secretId, secretKey: secretKey) else {
            updateStatus("保存失败：SecretId / SecretKey 不能为空")
            return
        }

        refreshTencentCredentialStatusUI()
        updateStatus("腾讯云密钥已保存并应用")
    }

    private func setupHotKey() {
        hotKeyManager = HotKeyManager { [weak self] in
            self?.toggleRecording()
        }
        refreshHotKeyMenuState()
    }

    private func refreshHotKeyMenuState() {
        let displayName = hotKeyManager?.currentShortcutDisplayName()
            ?? HotKeyManager.formatShortcutDisplayName(keyCodes: HotKeyManager.defaultShortcutKeyCodes)
        hotKeyInstructionMenuItem?.title = "按 \(displayName) 开始/停止录音"
        currentHotKeyMenuItem?.title = "当前快捷键: \(displayName)"
    }

    @objc private func openHotKeyConfiguration() {
        guard hotKeyCapturePanel == nil else {
            return
        }
        guard hotKeyManager != nil else {
            updateStatus("快捷键管理器未就绪")
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "快捷键设置"
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "按下你要设置的快捷键（支持 1 键或 2 键组合）")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        let hintLabel = NSTextField(labelWithString: "左右修饰键会明确显示，例如：左 Command / 右 Command")
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hintLabel)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 8
        statusLabel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        contentView.addSubview(statusLabel)

        let applyButton = NSButton(title: "应用", target: self, action: #selector(applyHotKeyConfiguration))
        applyButton.keyEquivalent = "\r"
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(applyButton)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelHotKeyConfiguration))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            statusLabel.heightAnchor.constraint(equalToConstant: 42),

            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cancelButton.widthAnchor.constraint(equalToConstant: 90),

            applyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            applyButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
            applyButton.widthAnchor.constraint(equalToConstant: 90)
        ])

        hotKeyCapturePanel = panel
        hotKeyCaptureStatusLabel = statusLabel
        hotKeyCapturePressedKeyCodes.removeAll()
        hotKeyCapturedKeyCodes = hotKeyManager.currentShortcutKeyCodes()
        statusLabel.stringValue = "当前: \(hotKeyManager.currentShortcutDisplayName())"

        hotKeyManager.setEnabled(false)
        startHotKeyCaptureMonitor()

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
    }

    @objc private func applyHotKeyConfiguration() {
        guard (1...2).contains(Set(hotKeyCapturedKeyCodes).count) else {
            hotKeyCaptureStatusLabel?.stringValue = "请先按下 1 或 2 个按键"
            NSSound.beep()
            return
        }
        guard hotKeyManager.updateShortcut(keyCodes: hotKeyCapturedKeyCodes) else {
            hotKeyCaptureStatusLabel?.stringValue = "快捷键无效，请重试"
            NSSound.beep()
            return
        }
        refreshHotKeyMenuState()
        updateStatus("快捷键已应用: \(hotKeyManager.currentShortcutDisplayName())")
        closeHotKeyConfigurationPanel()
    }

    @objc private func cancelHotKeyConfiguration() {
        hotKeyManager.resetToDefaultShortcut()
        refreshHotKeyMenuState()
        updateStatus("已取消，恢复默认快捷键: \(hotKeyManager.currentShortcutDisplayName())")
        closeHotKeyConfigurationPanel()
    }

    private func closeHotKeyConfigurationPanel() {
        stopHotKeyCaptureMonitor()
        if let panel = hotKeyCapturePanel {
            panel.orderOut(nil)
        }
        hotKeyCapturePanel = nil
        hotKeyCaptureStatusLabel = nil
        hotKeyCapturePressedKeyCodes.removeAll()
        hotKeyManager?.setEnabled(true)
        NSApp.stopModal()
    }

    private func startHotKeyCaptureMonitor() {
        stopHotKeyCaptureMonitor()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        hotKeyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleHotKeyCaptureEvent(event)
            return nil
        }
    }

    private func stopHotKeyCaptureMonitor() {
        if let hotKeyCaptureMonitor {
            NSEvent.removeMonitor(hotKeyCaptureMonitor)
            self.hotKeyCaptureMonitor = nil
        }
    }

    private func handleHotKeyCaptureEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.isARepeat {
                return
            }
            hotKeyCapturePressedKeyCodes.insert(event.keyCode)
        case .keyUp:
            hotKeyCapturePressedKeyCodes.remove(event.keyCode)
        case .flagsChanged:
            let keyCode = event.keyCode
            guard HotKeyManager.isModifierKeyCode(keyCode) else {
                return
            }
            toggleCapturedModifierKey(keyCode)
        default:
            break
        }
        updateHotKeyCapturePreview()
    }

    private func toggleCapturedModifierKey(_ keyCode: UInt16) {
        if hotKeyCapturePressedKeyCodes.contains(keyCode) {
            hotKeyCapturePressedKeyCodes.remove(keyCode)
        } else {
            hotKeyCapturePressedKeyCodes.insert(keyCode)
        }
    }

    private func updateHotKeyCapturePreview() {
        let normalized = HotKeyManager.normalizedShortcutKeyCodes(Array(hotKeyCapturePressedKeyCodes))
        if normalized.count > 2 {
            hotKeyCaptureStatusLabel?.stringValue = "最多支持 2 个按键，请重试"
            return
        }
        guard !normalized.isEmpty else {
            return
        }
        hotKeyCapturedKeyCodes = normalized
        hotKeyCaptureStatusLabel?.stringValue = "已捕获: \(HotKeyManager.formatShortcutDisplayName(keyCodes: normalized))"
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.updateMenuItem(title: "语音识别: 已授权")
                case .denied:
                    self.updateMenuItem(title: "语音识别: 被拒绝")
                case .restricted:
                    self.updateMenuItem(title: "语音识别: 限制")
                case .notDetermined:
                    self.updateMenuItem(title: "语音识别: 未确定")
                @unknown default:
                    break
                }
            }
        }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.updateMenuItem(title: "麦克风: 已授权")
                } else {
                    self.updateMenuItem(title: "麦克风: 被拒绝")
                }
            }
        }
    }

    private func toggleRecording() {
        if voiceInputManager.isRecording {
            voiceInputManager.stopRecording()
            updateStatus("正在识别...")
        } else {
            captureCurrentInputTargetApplication()
            voiceInputManager.startRecording()
            updateStatus("正在录音...")
        }
        updateIcon()
    }

    private func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let targetApp = resolveInputTargetApplication()
        if let targetApp {
            _ = targetApp.activate(options: [.activateAllWindows])
            print("[SmartVoiceIn] Activated target app: \(targetApp.localizedName ?? "Unknown")")
        } else {
            print("[SmartVoiceIn] No target app captured, pasting to current front app")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.simulatePaste()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if let previous = previousContents {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    private func captureCurrentInputTargetApplication() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return
        }

        if frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }

        lastInputTargetApplication = frontmost
        print("[SmartVoiceIn] Captured input target app: \(frontmost.localizedName ?? "Unknown")")
    }

    private func resolveInputTargetApplication() -> NSRunningApplication? {
        if let cached = lastInputTargetApplication, !cached.isTerminated {
            return cached
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return frontmost
        }
        return nil
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func updateStatus(_ status: String, autoHideAfter: TimeInterval? = nil) {
        statusHUDAutoHideWorkItem?.cancel()
        statusHUDAutoHideWorkItem = nil

        if let menu = statusItem.menu, menu.items.count > 0 {
            menu.items[0].title = "状态: \(status)"
        }
        statusHUD?.update(status: status)

        guard let autoHideAfter, autoHideAfter > 0 else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.statusHUD?.hide()
            self?.statusHUDAutoHideWorkItem = nil
        }
        statusHUDAutoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: workItem)
    }

    private func updateMenuItem(title: String) {
        if let menu = statusItem.menu {
            let item = menu.items.first(where: { $0.title.hasPrefix("语音") || $0.title.hasPrefix("麦克风") })
            item?.title = title
        }
    }

    private func updateIcon() {
        if let button = statusItem.button {
            if voiceInputManager.isRecording {
                button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Recording")
                button.contentTintColor = .systemRed
            } else {
                button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "SmartVoiceIn")
                button.contentTintColor = nil
            }
            button.image?.isTemplate = !voiceInputManager.isRecording
        }
    }

    private func currentASRProviderDisplayName() -> String {
        let rawValue = voiceInputManager.currentASRProviderRawValue()
        return asrProviderPresentations[rawValue]?.displayName ?? rawValue
    }

    private func switchWarningForASRProvider(rawValue: String) -> String? {
        if rawValue == "apple_speech" {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                return nil
            case .denied:
                return "当前语音识别权限被拒绝"
            case .restricted:
                return "当前语音识别权限受限制"
            case .notDetermined:
                return "尚未授予语音识别权限"
            @unknown default:
                return "语音识别权限状态未知"
            }
        }

        if rawValue == "qwen3_local" {
            return "首次识别可能需要加载/下载模型"
        }

        if rawValue == "tencent_cloud", !voiceInputManager.hasTencentCredentialsConfigured() {
            return "请先配置腾讯云 SecretId/SecretKey"
        }

        return nil
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

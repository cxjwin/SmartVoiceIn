import Cocoa
import Speech
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class StatusHUD {
    private let panel: NSPanel
    private let containerView: NSVisualEffectView
    private let statusLabel: NSTextField
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 8
    private let minWidth: CGFloat = 180
    private let maxWidth: CGFloat = 460
    private let bottomInset: CGFloat = 18

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
        let originY = visible.minY + bottomInset
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

    private enum PromptTemplateEditorMode {
        case create
        case edit(templateID: String)
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
    private var qwen3ASRModelStatusItem: NSMenuItem?
    private var optimizeProviderMenuItems: [String: NSMenuItem] = [:]
    private var promptTemplateMenuItems: [String: NSMenuItem] = [:]
    private var promptTemplateSubmenu: NSMenu?
    private var currentPromptTemplateStatusItem: NSMenuItem?
    private var editCurrentPromptTemplateMenuItem: NSMenuItem?
    private var deleteCurrentPromptTemplateMenuItem: NSMenuItem?
    private var localLLMModelStatusItem: NSMenuItem?
    private var tencentCredentialStatusItem: NSMenuItem?
    private var miniMaxCredentialStatusItem: NSMenuItem?
    private var statusHUDAutoHideWorkItem: DispatchWorkItem?
    private let asrProviderPresentations: [String: ASRProviderPresentation] = [
        "qwen3_local": ASRProviderPresentation(displayName: "Qwen3 本地模型", badge: "Q3"),
        "apple_speech": ASRProviderPresentation(displayName: "Apple Speech", badge: "SP"),
        "tencent_cloud": ASRProviderPresentation(displayName: "腾讯云 ASR", badge: "TC")
    ]

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppLog.log("App launched!")  // 调试用

        // 激活应用
        NSApp.activate(ignoringOtherApps: true)

        statusHUD = StatusHUD(initialStatus: "就绪")
        setupMenuBar()
        setupVoiceInput()
        setupHotKey()

        // 不再自动请求权限，用户需要手动在系统设置中授权
        AppLog.log("请在系统设置中授予权限:")
        AppLog.log("1. 系统设置 → 隐私与安全性 → 辅助功能 → 添加 SmartVoiceIn")
        AppLog.log("2. 系统设置 → 隐私与安全性 → 麦克风 → 添加 SmartVoiceIn")
        AppLog.log("3. 系统设置 → 隐私与安全性 → 语音识别 → 添加 SmartVoiceIn")
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
                        let providerName = self?.currentASRProviderDisplayName() ?? "未知引擎"
                        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalized.isEmpty else {
                            self?.updateStatus("识别成功(\(providerName)): 无有效文本", autoHideAfter: 3)
                            return
                        }
                        self?.insertText(normalized)
                        self?.updateStatus("识别成功(\(providerName)): \(normalized)", autoHideAfter: 5)
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
        refreshPromptTemplateMenuState()
        refreshTextOptimizeCredentialStatusUI()
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

        submenu.addItem(NSMenuItem.separator())
        qwen3ASRModelStatusItem = NSMenuItem(title: "Qwen3 模型: 未配置", action: nil, keyEquivalent: "")
        qwen3ASRModelStatusItem?.isEnabled = false
        if let qwen3ASRModelStatusItem {
            submenu.addItem(qwen3ASRModelStatusItem)
        }

        let qwen3ModelConfigItem = NSMenuItem(title: "设置 Qwen3 模型...", action: #selector(openQwen3ASRModelConfiguration), keyEquivalent: "")
        qwen3ModelConfigItem.target = self
        submenu.addItem(qwen3ModelConfigItem)

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
        let qwen3ModelID = voiceInputManager?.currentQwen3ASRModelIDValue() ?? Qwen3ASRProvider.defaultModelID
        qwen3ASRModelStatusItem?.title = "Qwen3 模型: \(qwen3ModelID)"

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
        submenu.addItem(makePromptTemplateMenuItem())
        submenu.addItem(NSMenuItem.separator())

        localLLMModelStatusItem = NSMenuItem(title: "本地模型: 未配置", action: nil, keyEquivalent: "")
        localLLMModelStatusItem?.isEnabled = false
        if let localLLMModelStatusItem {
            submenu.addItem(localLLMModelStatusItem)
        }

        let localModelConfigItem = NSMenuItem(title: "设置本地模型...", action: #selector(openLocalLLMModelConfiguration), keyEquivalent: "")
        localModelConfigItem.target = self
        submenu.addItem(localModelConfigItem)

        submenu.addItem(NSMenuItem.separator())

        tencentCredentialStatusItem = NSMenuItem(title: "腾讯云密钥: 未配置", action: nil, keyEquivalent: "")
        tencentCredentialStatusItem?.isEnabled = false
        if let tencentCredentialStatusItem {
            submenu.addItem(tencentCredentialStatusItem)
        }

        let configItem = NSMenuItem(title: "设置腾讯云密钥...", action: #selector(openTencentCredentialConfiguration), keyEquivalent: "")
        configItem.target = self
        submenu.addItem(configItem)

        submenu.addItem(NSMenuItem.separator())

        miniMaxCredentialStatusItem = NSMenuItem(title: "MiniMax Key: 未配置", action: nil, keyEquivalent: "")
        miniMaxCredentialStatusItem?.isEnabled = false
        if let miniMaxCredentialStatusItem {
            submenu.addItem(miniMaxCredentialStatusItem)
        }

        let miniMaxConfigItem = NSMenuItem(title: "设置 MiniMax API Key...", action: #selector(openMiniMaxCredentialConfiguration), keyEquivalent: "")
        miniMaxConfigItem.target = self
        submenu.addItem(miniMaxConfigItem)

        parent.submenu = submenu
        return parent
    }

    private func makePromptTemplateMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "提示词模板", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        parent.submenu = submenu
        promptTemplateSubmenu = submenu
        reloadPromptTemplateMenu()
        return parent
    }

    private func reloadPromptTemplateMenu() {
        guard let submenu = promptTemplateSubmenu else {
            return
        }

        submenu.removeAllItems()
        promptTemplateMenuItems.removeAll()

        let currentTemplate = LLMPromptTemplateStore.currentTemplate()
        let currentItem = NSMenuItem(title: "当前模板: \(currentTemplate.title)", action: nil, keyEquivalent: "")
        currentItem.isEnabled = false
        currentPromptTemplateStatusItem = currentItem
        submenu.addItem(currentItem)
        submenu.addItem(NSMenuItem.separator())

        let templates = LLMPromptTemplateStore.allTemplates()
        let selectedTemplateID = LLMPromptTemplateStore.currentTemplateID()
        for template in templates {
            let item = NSMenuItem(title: promptTemplateDisplayTitle(template), action: #selector(selectPromptTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template.id
            item.state = (template.id == selectedTemplateID) ? .on : .off
            promptTemplateMenuItems[template.id] = item
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())
        let addTemplateItem = NSMenuItem(title: "新增模板...", action: #selector(openPromptTemplateConfiguration), keyEquivalent: "")
        addTemplateItem.target = self
        submenu.addItem(addTemplateItem)

        editCurrentPromptTemplateMenuItem = NSMenuItem(title: "编辑当前模板...", action: #selector(openCurrentPromptTemplateEditor), keyEquivalent: "")
        editCurrentPromptTemplateMenuItem?.target = self
        if let editCurrentPromptTemplateMenuItem {
            submenu.addItem(editCurrentPromptTemplateMenuItem)
        }

        deleteCurrentPromptTemplateMenuItem = NSMenuItem(title: "删除当前模板", action: #selector(deleteCurrentPromptTemplate), keyEquivalent: "")
        deleteCurrentPromptTemplateMenuItem?.target = self
        if let deleteCurrentPromptTemplateMenuItem {
            submenu.addItem(deleteCurrentPromptTemplateMenuItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let exportTemplatesItem = NSMenuItem(title: "导出自定义模板...", action: #selector(exportPromptTemplates), keyEquivalent: "")
        exportTemplatesItem.target = self
        submenu.addItem(exportTemplatesItem)

        let importTemplatesItem = NSMenuItem(title: "导入模板...", action: #selector(importPromptTemplates), keyEquivalent: "")
        importTemplatesItem.target = self
        submenu.addItem(importTemplatesItem)

        let currentIsBuiltIn = currentTemplate.isBuiltIn
        editCurrentPromptTemplateMenuItem?.isEnabled = !currentIsBuiltIn
        deleteCurrentPromptTemplateMenuItem?.isEnabled = !currentIsBuiltIn
    }

    private func refreshOptimizeProviderMenuState() {
        let selected = voiceInputManager?.currentTextOptimizeProviderRawValue()
        for (rawValue, item) in optimizeProviderMenuItems {
            item.state = (rawValue == selected) ? .on : .off
        }
    }

    private func refreshPromptTemplateMenuState() {
        if promptTemplateSubmenu == nil || promptTemplateMenuItems.isEmpty {
            reloadPromptTemplateMenu()
            return
        }

        let currentTemplate = LLMPromptTemplateStore.currentTemplate()
        currentPromptTemplateStatusItem?.title = "当前模板: \(currentTemplate.title)"
        for (templateID, item) in promptTemplateMenuItems {
            item.state = (templateID == currentTemplate.id) ? .on : .off
        }
        editCurrentPromptTemplateMenuItem?.isEnabled = !currentTemplate.isBuiltIn
        deleteCurrentPromptTemplateMenuItem?.isEnabled = !currentTemplate.isBuiltIn
    }

    private func refreshTextOptimizeCredentialStatusUI() {
        let localModelID = voiceInputManager?.currentLocalLLMModelIDValue() ?? "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        localLLMModelStatusItem?.title = "本地模型: \(localModelID)"
        let configured = voiceInputManager?.hasTencentCredentialsConfigured() ?? false
        tencentCredentialStatusItem?.title = configured ? "腾讯云密钥: 已配置" : "腾讯云密钥: 未配置"
        let miniMaxConfigured = voiceInputManager?.hasMiniMaxAPIKeyConfigured() ?? false
        miniMaxCredentialStatusItem?.title = miniMaxConfigured ? "MiniMax Key: 已配置" : "MiniMax Key: 未配置"
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
            updateStatus("切换失败: 提供方不可用或配置缺失")
            return
        }
        refreshOptimizeProviderMenuState()
        updateStatus("文本优化模型: \(displayName)")
    }

    @objc private func selectPromptTemplate(_ sender: NSMenuItem) {
        guard let templateID = sender.representedObject as? String else {
            updateStatus("切换失败: 无效的提示词模板")
            return
        }
        guard LLMPromptTemplateStore.setCurrentTemplate(id: templateID) else {
            updateStatus("切换失败: 未找到提示词模板")
            return
        }
        refreshPromptTemplateMenuState()
        updateStatus("提示词模板: \(LLMPromptTemplateStore.currentTemplate().title)")
    }

    @objc private func openPromptTemplateConfiguration() {
        openPromptTemplateEditor(mode: .create)
    }

    @objc private func openCurrentPromptTemplateEditor() {
        let currentTemplate = LLMPromptTemplateStore.currentTemplate()
        guard !currentTemplate.isBuiltIn else {
            updateStatus("内置模板不支持编辑，请通过“新增模板...”创建自定义模板")
            return
        }
        openPromptTemplateEditor(mode: .edit(templateID: currentTemplate.id))
    }

    private func openPromptTemplateEditor(mode: PromptTemplateEditorMode) {
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        let initialTitle: String
        let initialPrompt: String
        let messageText: String
        let informativeText: String
        let confirmButtonTitle: String

        switch mode {
        case .create:
            initialTitle = ""
            initialPrompt = LLMPromptTemplateStore.defaultTemplatePrompt()
            messageText = "新增提示词模板"
            informativeText = "填写模板标题和 Prompt 内容，保存后可在“文本优化模型 -> 提示词模板”中切换。"
            confirmButtonTitle = "保存并使用"
        case .edit(let templateID):
            guard let template = LLMPromptTemplateStore.template(withID: templateID), !template.isBuiltIn else {
                updateStatus("编辑失败：模板不存在或不可编辑")
                return
            }
            initialTitle = template.title
            initialPrompt = template.prompt
            messageText = "编辑提示词模板"
            informativeText = "修改模板标题和 Prompt 内容，保存后会立即生效。"
            confirmButtonTitle = "保存修改"
        }

        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "模板标题")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(titleLabel)

        let titleField = NSTextField(string: initialTitle)
        titleField.placeholderString = "例如：会议纪要清洗"
        titleField.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(titleField)

        let promptLabel = NSTextField(labelWithString: "Prompt 模板")
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(promptLabel)

        let promptScrollView = NSScrollView()
        promptScrollView.borderType = .bezelBorder
        promptScrollView.hasVerticalScroller = true
        promptScrollView.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(promptScrollView)

        let promptTextView = NSTextView()
        promptTextView.isRichText = false
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        promptTextView.string = initialPrompt
        promptScrollView.documentView = promptTextView

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: accessory.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            titleField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            promptLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 12),
            promptLabel.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            promptLabel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            promptScrollView.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 6),
            promptScrollView.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            promptScrollView.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            promptScrollView.heightAnchor.constraint(equalToConstant: 160),
            promptScrollView.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else {
            updateStatus("已取消模板操作")
            return
        }

        let title = titleField.stringValue
        let prompt = promptTextView.string

        switch mode {
        case .create:
            guard let newTemplate = LLMPromptTemplateStore.addCustomTemplate(title: title, prompt: prompt) else {
                updateStatus("保存失败：模板标题和 Prompt 不能为空")
                return
            }
            _ = LLMPromptTemplateStore.setCurrentTemplate(id: newTemplate.id)
            reloadPromptTemplateMenu()
            refreshPromptTemplateMenuState()
            updateStatus("提示词模板已新增并切换: \(newTemplate.title)")
        case .edit(let templateID):
            guard LLMPromptTemplateStore.updateCustomTemplate(id: templateID, title: title, prompt: prompt) else {
                updateStatus("保存失败：模板标题和 Prompt 不能为空")
                return
            }
            _ = LLMPromptTemplateStore.setCurrentTemplate(id: templateID)
            reloadPromptTemplateMenu()
            refreshPromptTemplateMenuState()
            updateStatus("提示词模板已更新: \(title.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    @objc private func deleteCurrentPromptTemplate() {
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        let currentTemplate = LLMPromptTemplateStore.currentTemplate()
        guard !currentTemplate.isBuiltIn else {
            updateStatus("内置模板不支持删除")
            return
        }

        let alert = NSAlert()
        alert.messageText = "删除提示词模板"
        alert.informativeText = "确认删除模板「\(currentTemplate.title)」？此操作不可恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            updateStatus("已取消删除模板")
            return
        }

        guard LLMPromptTemplateStore.deleteCustomTemplate(id: currentTemplate.id) else {
            updateStatus("删除失败：模板不存在")
            return
        }
        reloadPromptTemplateMenu()
        refreshPromptTemplateMenuState()
        updateStatus("提示词模板已删除: \(currentTemplate.title)")
    }

    @objc private func exportPromptTemplates() {
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        guard LLMPromptTemplateStore.customTemplateCount() > 0 else {
            updateStatus("暂无可导出的自定义模板")
            return
        }
        guard let data = LLMPromptTemplateStore.exportCustomTemplates() else {
            updateStatus("导出失败：无法生成模板文件")
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "smartvoicein-llm-templates.json"
        panel.allowedContentTypes = [UTType.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            updateStatus("已取消导出模板")
            return
        }

        do {
            try data.write(to: url)
            updateStatus("模板导出成功: \(url.lastPathComponent)")
        } catch {
            updateStatus("模板导出失败: \(error.localizedDescription)")
        }
    }

    @objc private func importPromptTemplates() {
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            updateStatus("已取消导入模板")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let importedCount = LLMPromptTemplateStore.importCustomTemplates(from: data)
            reloadPromptTemplateMenu()
            refreshPromptTemplateMenuState()
            if importedCount > 0 {
                updateStatus("模板导入成功: 新增 \(importedCount) 个")
            } else {
                updateStatus("模板导入完成：没有新增内容")
            }
        } catch {
            updateStatus("模板导入失败: \(error.localizedDescription)")
        }
    }

    private func promptTemplateDisplayTitle(_ template: LLMPromptTemplate) -> String {
        return template.isBuiltIn ? "\(template.title)（内置）" : template.title
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
        let tencentWindow = alert.window
        tencentWindow.initialFirstResponder = secretIdField
        tencentWindow.makeFirstResponder(secretIdField)
        NSApp.activate(ignoringOtherApps: true)

        guard runModalAlertWithEditingShortcuts(alert, preferredFirstResponder: secretIdField) == .alertFirstButtonReturn else {
            updateStatus("已取消腾讯云密钥更新")
            return
        }

        let secretId = secretIdField.stringValue
        let secretKey = secretKeyField.stringValue
        guard voiceInputManager.updateTencentCredentials(secretId: secretId, secretKey: secretKey) else {
            updateStatus("保存失败：SecretId / SecretKey 不能为空")
            return
        }

        refreshTextOptimizeCredentialStatusUI()
        updateStatus("腾讯云密钥已保存并应用")
    }

    @objc private func openMiniMaxCredentialConfiguration() {
        guard voiceInputManager != nil else {
            updateStatus("配置未就绪，请稍后重试")
            return
        }
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        let existingAPIKey = voiceInputManager.currentMiniMaxAPIKeyValue() ?? ""

        let alert = NSAlert()
        alert.messageText = "MiniMax API Key 设置"
        alert.informativeText = "输入 API Key，保存后将持久化到本地并立即应用。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存并应用")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let apiKeyLabel = NSTextField(labelWithString: "API Key")
        apiKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(apiKeyLabel)

        let apiKeyField = NSSecureTextField(string: existingAPIKey)
        apiKeyField.placeholderString = "输入 MiniMax API Key"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(apiKeyField)

        NSLayoutConstraint.activate([
            apiKeyLabel.topAnchor.constraint(equalTo: accessory.topAnchor),
            apiKeyLabel.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            apiKeyLabel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            apiKeyField.topAnchor.constraint(equalTo: apiKeyLabel.bottomAnchor, constant: 6),
            apiKeyField.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            apiKeyField.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            apiKeyField.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        alert.accessoryView = accessory
        let miniMaxWindow = alert.window
        miniMaxWindow.initialFirstResponder = apiKeyField
        miniMaxWindow.makeFirstResponder(apiKeyField)
        NSApp.activate(ignoringOtherApps: true)

        guard runModalAlertWithEditingShortcuts(alert, preferredFirstResponder: apiKeyField) == .alertFirstButtonReturn else {
            updateStatus("已取消 MiniMax API Key 更新")
            return
        }

        let apiKey = apiKeyField.stringValue
        guard voiceInputManager.updateMiniMaxAPIKey(apiKey: apiKey) else {
            updateStatus("保存失败：MiniMax API Key 不能为空")
            return
        }

        refreshTextOptimizeCredentialStatusUI()
        updateStatus("MiniMax API Key 已保存并应用")
    }

    @objc private func openLocalLLMModelConfiguration() {
        guard voiceInputManager != nil else {
            updateStatus("配置未就绪，请稍后重试")
            return
        }
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        let existingModelID = voiceInputManager.currentLocalLLMModelIDValue() ?? "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

        let alert = NSAlert()
        alert.messageText = "本地 LLM 模型设置"
        alert.informativeText = "输入 Hugging Face 模型 ID，保存后将持久化到本地并立即应用。示例：mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存并应用")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 84))
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let modelIDLabel = NSTextField(labelWithString: "Model ID")
        modelIDLabel.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(modelIDLabel)

        let modelIDField = NSTextField(string: existingModelID)
        modelIDField.placeholderString = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        modelIDField.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(modelIDField)

        NSLayoutConstraint.activate([
            accessory.widthAnchor.constraint(equalToConstant: 620),
            modelIDLabel.topAnchor.constraint(equalTo: accessory.topAnchor),
            modelIDLabel.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            modelIDLabel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            modelIDField.topAnchor.constraint(equalTo: modelIDLabel.bottomAnchor, constant: 6),
            modelIDField.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            modelIDField.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            modelIDField.widthAnchor.constraint(equalToConstant: 620),
            modelIDField.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        alert.accessoryView = accessory
        let localModelWindow = alert.window
        localModelWindow.initialFirstResponder = modelIDField
        localModelWindow.makeFirstResponder(modelIDField)
        NSApp.activate(ignoringOtherApps: true)

        guard runModalAlertWithEditingShortcuts(alert, preferredFirstResponder: modelIDField) == .alertFirstButtonReturn else {
            updateStatus("已取消本地模型更新")
            return
        }

        let modelID = modelIDField.stringValue
        guard voiceInputManager.updateLocalLLMModelID(modelID: modelID) else {
            updateStatus("保存失败：Model ID 不能为空")
            return
        }

        refreshTextOptimizeCredentialStatusUI()
        updateStatus("本地模型已保存并应用: \(modelID.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    @objc private func openQwen3ASRModelConfiguration() {
        guard voiceInputManager != nil else {
            updateStatus("配置未就绪，请稍后重试")
            return
        }
        hotKeyManager?.setEnabled(false)
        defer {
            hotKeyManager?.setEnabled(true)
        }

        let existingModelID = voiceInputManager.currentQwen3ASRModelIDValue() ?? Qwen3ASRProvider.defaultModelID

        let alert = NSAlert()
        alert.messageText = "Qwen3 ASR 模型设置"
        alert.informativeText = "输入 Hugging Face 模型 ID，保存后将持久化到本地并立即应用。支持：mlx-community/Qwen3-ASR-0.6B-4bit / mlx-community/Qwen3-ASR-1.7B-8bit"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存并应用")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 84))
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let modelIDLabel = NSTextField(labelWithString: "Model ID")
        modelIDLabel.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(modelIDLabel)

        let modelIDField = NSTextField(string: existingModelID)
        modelIDField.placeholderString = Qwen3ASRProvider.defaultModelID
        modelIDField.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(modelIDField)

        NSLayoutConstraint.activate([
            accessory.widthAnchor.constraint(equalToConstant: 620),
            modelIDLabel.topAnchor.constraint(equalTo: accessory.topAnchor),
            modelIDLabel.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            modelIDLabel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),

            modelIDField.topAnchor.constraint(equalTo: modelIDLabel.bottomAnchor, constant: 6),
            modelIDField.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            modelIDField.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            modelIDField.widthAnchor.constraint(equalToConstant: 620),
            modelIDField.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        alert.accessoryView = accessory
        let localModelWindow = alert.window
        localModelWindow.initialFirstResponder = modelIDField
        localModelWindow.makeFirstResponder(modelIDField)
        NSApp.activate(ignoringOtherApps: true)

        guard runModalAlertWithEditingShortcuts(alert, preferredFirstResponder: modelIDField) == .alertFirstButtonReturn else {
            updateStatus("已取消 Qwen3 模型更新")
            return
        }

        let modelID = modelIDField.stringValue
        guard voiceInputManager.updateQwen3ASRModelID(modelID: modelID) else {
            updateStatus("保存失败：仅支持 0.6B-4bit 或 1.7B-8bit")
            return
        }

        refreshASRProviderUI()
        let appliedModelID = voiceInputManager.currentQwen3ASRModelIDValue() ?? Qwen3ASRProvider.defaultModelID
        updateStatus("Qwen3 模型已保存并应用: \(appliedModelID)")
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
            guard let self, self.hotKeyCapturePanel != nil else {
                return event
            }
            self.handleHotKeyCaptureEvent(event)
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

    private func runModalAlertWithEditingShortcuts(
        _ alert: NSAlert,
        preferredFirstResponder: NSView
    ) -> NSApplication.ModalResponse {
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = preferredFirstResponder
        alertWindow.makeFirstResponder(preferredFirstResponder)
        DispatchQueue.main.async { [weak alertWindow, weak preferredFirstResponder] in
            guard let alertWindow, let preferredFirstResponder else { return }
            alertWindow.makeFirstResponder(preferredFirstResponder)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak alertWindow, weak preferredFirstResponder] in
            guard let alertWindow, let preferredFirstResponder else { return }
            alertWindow.makeFirstResponder(preferredFirstResponder)
        }
        NSApp.activate(ignoringOtherApps: true)

        var editingShortcutMonitor: Any?
        editingShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let unsupportedFlags = flags.subtracting([.command, .shift])
            guard unsupportedFlags.isEmpty,
                  flags.contains(.command) else {
                return event
            }

            let keyCode = event.keyCode
            let action: Selector
            switch keyCode {
            case 8:
                action = #selector(NSText.copy(_:))
            case 9:
                action = #selector(NSText.paste(_:))
            case 7:
                action = #selector(NSText.cut(_:))
            case 0:
                action = #selector(NSText.selectAll(_:))
            case 6:
                action = flags.contains(.shift) ? #selector(UndoManager.redo) : #selector(UndoManager.undo)
            default:
                return event
            }

            if let responder = alertWindow.firstResponder,
               responder.tryToPerform(action, with: nil) {
                return nil
            }

            _ = alertWindow.makeFirstResponder(preferredFirstResponder)
            if let responder = alertWindow.firstResponder,
               responder.tryToPerform(action, with: nil) {
                return nil
            }

            _ = NSApp.sendAction(action, to: nil, from: nil)
            return nil
        }

        defer {
            if let editingShortcutMonitor {
                NSEvent.removeMonitor(editingShortcutMonitor)
            }
        }

        return alert.runModal()
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
            AppLog.log("[SmartVoiceIn] Activated target app: \(targetApp.localizedName ?? "Unknown")")
        } else {
            AppLog.log("[SmartVoiceIn] No target app captured, pasting to current front app")
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
        AppLog.log("[SmartVoiceIn] Captured input target app: \(frontmost.localizedName ?? "Unknown")")
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

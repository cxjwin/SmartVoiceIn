# SmartVoiceIn

一个 macOS 菜单栏语音输入工具：按右 `Command` 开始/停止录音，将语音转文本并自动粘贴到当前输入框。

## 当前能力

- 右 `Command` 热键触发录音与停止
- 菜单支持快捷键自定义：
  - 支持 `1` 键或 `2` 键组合
  - 区分左/右修饰键（例如左 Command、右 Command）
  - 配置弹窗提供 `应用` 与 `取消`（取消会恢复默认右 Command）
- 菜单可切换语音识别引擎：
  - `Qwen3 本地模型`
  - `Apple Speech`
  - `腾讯云 ASR`
- 默认主链路为本地 Qwen3-ASR（`qwen3-asr-swift`），失败自动回退本地 `Speech`
- 识别后文本后处理：
  - 优先 LLM 优化（可切换提供方）
  - 失败自动回退本地轻清洗（去口头禅、去重复）
- 菜单可切换文本优化模型提供方：
  - `本地 MLX (Qwen2.5-0.5B)`（默认）
  - `腾讯混元`
- 菜单支持腾讯云密钥配置：
  - 支持输入/更新 `SecretId`、`SecretKey`
  - 保存后持久化到本地并立即生效

## 项目结构

- `Sources/App/main.swift`：App 启动、菜单栏 UI、状态更新
- `Sources/ASR/ASRProvider.swift`：ASR 抽象与音频文件构建
- `Sources/ASR/Local/Qwen3ASRProvider.swift`：本地 ASR（Qwen3）
- `Sources/ASR/Remote/TencentASRProvider.swift`：远程 ASR（腾讯云）
- `Sources/LLMText/Core/LLMTextOptimizer.swift`：文本优化入口与 provider 管理
- `Sources/LLMText/Core/LLMTextOptimizeTypes.swift`：文本优化公共协议/配置/Prompt
- `Sources/LLMText/Local/LocalMLXLLMProvider.swift`：本地文本优化（MLX）
- `Sources/LLMText/Remote/TencentHunyuanLLMProvider.swift`：远程文本优化（腾讯混元）
- `Sources/HotKey/HotKeyManager.swift`：全局快捷键监听与管理
- `Sources/VoiceInput/VoiceInputManager.swift`：录音、重采样、ASR 调用与后处理

## 运行要求

- macOS 15+
- Xcode 16+
- 麦克风、辅助功能、语音识别权限

## 本地 ASR 配置（Qwen3）

- `VOICEINPUT_QWEN3_MODEL=mlx-community/Qwen3-ASR-0.6B-4bit`（可选，默认值）

首次识别时会自动下载模型到 HuggingFace 本地缓存，后续离线可直接使用本地模型。

## ASR 引擎配置（可选）

- `VOICEINPUT_ASR_PROVIDER=qwen3_local`（默认）
- `VOICEINPUT_ASR_PROVIDER=apple_speech`
- `VOICEINPUT_ASR_PROVIDER=tencent_cloud`

说明：
- 也可以在菜单栏 `语音识别引擎` 中切换。
- 菜单切换会写入 `UserDefaults`，优先级高于环境变量。
- 使用 `tencent_cloud` 时，需要可用的腾讯云密钥（菜单配置或环境变量）。

## 构建

```bash
xcodegen generate
xcodebuild -project "VoiceInput.xcodeproj" -scheme "VoiceInput" -configuration Debug build
```

## App 测试执行步骤

1. 启动工程并运行 App
   - `cd /Users/smart/Desktop/demo/VoiceInput`
   - `open VoiceInput.xcodeproj`
   - 在 Xcode 中运行 `VoiceInput` scheme（`Debug` + `My Mac`，产物为 `SmartVoiceIn.app`）
2. 确认 UI 初始状态
   - 菜单栏出现麦克风图标
   - 屏幕顶部出现悬浮状态控件，初始显示 `就绪`
3. 首次权限授权
   - 系统设置中为 `SmartVoiceIn` 开启：`麦克风`、`语音识别`、`辅助功能`
4. 验证基础录音链路
   - 按右 `Command` 开始录音，再按一次停止
   - 预期状态顺序：`正在录音...` -> `正在识别...` -> `识别成功(...)` 或 `识别失败(...)`
5. 验证 ASR 引擎切换
   - 菜单栏 -> `语音识别引擎`，在 `Qwen3 本地模型`、`Apple Speech`、`腾讯云 ASR` 间切换
   - 预期：勾选状态变化；菜单中的 `当前引擎` 同步变化；状态栏按钮短标识在 `Q3`/`SP`/`TC` 间切换
6. 验证 LLM 转换 loading（需已配置 LLM）
   - 说一段较长语句并停止录音
   - 预期出现：`正在转换中（LLM 文本优化）...`
   - 若 LLM 请求失败，预期出现：`转换失败，正在回退本地清洗...`，并最终返回文本结果
7. 回归稳定性检查
   - 连续重复 3-5 次短句输入
   - 预期无卡死，悬浮状态持续刷新，文本可正常粘贴到当前输入框

## 文本优化配置（可选）

未配置时，自动回退本地清洗逻辑。

### 本地 MLX 模式（默认）

- `VOICEINPUT_LLM_PROVIDER=local_mlx`（可省略，默认）
- `VOICEINPUT_LOCAL_LLM_MODEL=mlx-community/Qwen2.5-0.5B-Instruct-4bit`（可选）
- `VOICEINPUT_LOCAL_LLM_MAX_TOKENS=160`（可选）

说明：
- 首次调用会自动下载模型到本地缓存，后续可离线使用。

### 腾讯混元模式

- `VOICEINPUT_LLM_PROVIDER=tencent_hunyuan`
- `VOICEINPUT_TENCENT_SECRET_ID=...`（必填）
- `VOICEINPUT_TENCENT_SECRET_KEY=...`（必填）
- `VOICEINPUT_LLM_ENDPOINT=https://hunyuan.tencentcloudapi.com`（可选）
- `VOICEINPUT_TENCENT_REGION=ap-guangzhou`（可选）
- `VOICEINPUT_LLM_MODEL=hunyuan-lite`（可选）
- `VOICEINPUT_LLM_TIMEOUT=6`（可选）

说明：
- `LLMTextOptimizer` 已改成 Provider 形式，后续新增提供方只需扩展 provider 并注册。
- 也可在菜单栏 `文本优化模型 -> 设置腾讯云密钥...` 里手动配置密钥。
- 菜单保存的本地密钥会在下次启动继续生效；若未配置本地密钥，则回退使用环境变量。

## 备注

- 当前代码已具备调试日志，便于定位识别和后处理链路。

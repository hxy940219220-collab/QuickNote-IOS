# QuickNote · AI 便签

**边记边问，把 AI 的结果写进自己的便签。**

QuickNote 是一款原生 macOS AI 便签。学习或工作时，遇到难懂的文字就划词，遇到图片里的信息就截图。让 AI 翻译、解释、分析，或者直接问一个问题，再把有用的结果存回正在整理的便签。读到新资料时可以继续补充，回顾时也可以请 Codex 整理已有内容，把确认过的结果追加回去。

支持 **macOS 14+**。[查看功能演示](https://www.huangxiyuan.net/projects/quicknote)

## 边看、边问、边记

读英文资料时，选中一句话让 AI 翻译，再截取文章里的图表问它「这张图说明了什么？」。译文和图表要点可以存入同一条学习便签。之后看到新材料，继续把解释、例子和自己的理解补进去。

- **文本划词**：按 **Option + Space** 打开面板，翻译、解释、分析或拓展选中的文字，也可以针对原文输入自己的问题。
- **截图识图**：按 **Command + Shift** 框选图片或屏幕区域。可以提取文字、翻译、总结、整理表格、生成待办、排查问题，也可以直接针对图片提问。
- **结果直接存入便签**：划词和识图共用「存入」入口，可选已有便签，也可新建。原文、截图和分析结果可以按需收下，之后继续编辑。

| 划词提问和存入便签 | 截图分析和存入便签 |
|---|---|
| ![划词弹窗的结果、存入按钮及发送范围说明](docs/images/current/selection.webp) | ![图片识别窗口的原图、快捷指令及分析结果](docs/images/current/screenshot-ai.png) |

## 接入 AI 的两种方式

打开 **设置 → AI 模型**，按自己的使用习惯选择。

| 接入方式 | 怎么用 |
|---|---|
| **ChatGPT 账号** | 安装本机 Codex CLI 后，选择「ChatGPT 账号（Codex）」，用已有 ChatGPT 账号登录，无需另填 API Key。 |
| **模型 API** | 配置自己的模型 API，选择用于文字和图片的模型。识图需要选择支持图片输入的模型。 |

划词、识图、AI 排版、语音整理和便签问答可以按功能指定模型来源。Codex 设置中可查看登录状态、可用模型、推理档位和返回的额度。

![QuickNote 的 AI 设置，可在 ChatGPT 账号和 API 之间选择](docs/images/current/codex-settings.png)

## 让本机 Codex 接着整理便签

在 Codex 里可以通过 **MCP** 搜索和读取 QuickNote 中你授权的便签。例如，让 Codex 读取几条学习笔记，整理一份复习提纲，再提议新建便签或把提纲追加到原笔记。你在 QuickNote 内查看并确认后，提议才会写入。

1. 在 QuickNote 打开「设置 → Codex 读取便签」，开启「读取授权便签」，勾选允许访问的文件夹或「便签集」。**敏感便签始终排除。**
2. 在终端注册随应用构建的 MCP 工具。下例使用 `/Applications` 安装路径。

   ```sh
   codex mcp add quicknote -- /Applications/QuickNote.app/Contents/MacOS/quicknote-mcp
   ```

3. 保持 QuickNote 打开，在 Codex 新会话中搜索或读取便签。需要写入时，另行开启「允许写入提议」，再回 QuickNote 审核和确认。

![QuickNote 的 MCP 授权位置和写入提议开关](docs/images/current/mcp-authorization.webp)

## 继续用已有的笔记

- **问我的便签**：在搜索面板按 Tab 切到提问。QuickNote 在本机检索非敏感便签的相关片段，由所选模型回答，点击引用可回到原文。
- **本地全文搜索**：搜索标题、正文和标签，可在同一便签的不同命中之间切换。
- **离线语音转写**：先在 Mac 上把录音转成文字，再按设置让 AI 整理本次转写。整理失败时保留原文。
- **原生编辑与 AI 排版**：双击 Command 打开便签，使用富文本、表格、清单、附件和文件夹整理内容。AI 排版方案可以先预览再应用。

![问我的便签展示由合成资料生成的回答及原文引用](docs/images/current/note-ask.webp)

截图均使用合成便签、演示账号和示例结果。

## 数据与权限

便签与附件保存在本机 `~/Library/Application Support/QuickNote/`，API Key 由 macOS 钥匙串保护。基础编辑、全文搜索和离线语音转写可以在本机完成。

调用在线模型时，界面会显示处理来源。本机 Codex 指在 Mac 上运行的 CLI，模型请求由 ChatGPT 服务处理。QuickNote 发给 Codex 的模型请求使用临时会话，关闭命令执行和 MCP 工具。问便签发送本次问题和检索片段，语音整理发送本次转写文字。Codex 通过 MCP 可访问的范围由你单独授权。

## 从源码构建

需要 macOS 14+、Xcode 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。离线语音模型由脚本按需下载并校验，首次约 230 MB。

```sh
brew install xcodegen
bash scripts/prepare-offline-speech.sh
xcodegen generate
xcodebuild build -project QuickNote.xcodeproj -scheme QuickNote \
  -configuration Release -derivedDataPath /tmp/QuickNoteDerived
open /tmp/QuickNoteDerived/Build/Products/Release/QuickNote.app
```

上面的构建适合本地试用。若要用同一签名身份持续升级，请设置本人的 `QUICKNOTE_SIGNING_IDENTITY` 和 `QUICKNOTE_DEVELOPMENT_TEAM`，再运行 `./scripts/verify-p0.sh`。首次使用快捷键、划词或截图时，请按系统提示授权输入监控、辅助功能与屏幕录制。

离线模型及原生运行时的许可证位于 `QuickNote/Resources/Speech/`。

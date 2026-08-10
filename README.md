# QuickNote

QuickNote 是一款本地优先的 macOS 便签工具。双击 Command 即刻唤起，记录完成后回到原来的工作流；选中文字后按 Option + Space，可以直接解释、分析、翻译或拓展，并保留排版导入便签。

![QuickNote 界面](docs/quicknote-ui.png)

## 功能

- 双击 Command 快速打开或收起便签
- 第一行默认作为大号标题，正文统一使用系统 13pt 字体
- 文件夹分类、搜索、固定与侧边快速切换
- 富文本、清单、表格、链接、图片、文件和音频附件
- Command + Z 逐步撤销文字与格式操作
- 五套主题配色
- 选中文字后调用 AI，并将结构化结果保留格式导入
- RTFD 本地持久化，API Key 存入 macOS 钥匙串

## 环境

- macOS 14+
- Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 构建

```bash
brew install xcodegen
./scripts/verify-p0.sh
open /tmp/QuickNoteDerived/Build/Products/Release/QuickNote.app
```

首次使用快捷键时，请按应用内说明开启“输入监控”和“辅助功能”权限。

## 数据与隐私

便签保存在本机 `~/Library/Application Support/QuickNote/`。基础记录功能不依赖 AI；只有用户主动调用 AI 功能时，所选内容才会发送到用户配置的模型服务。

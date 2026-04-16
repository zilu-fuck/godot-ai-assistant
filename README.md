# Godot AI Assistant v2.1

这是一个面向 Godot 4 编辑器的 AI 编码助手插件，核心代码位于 [addons/ai_assistant](E:/test/addons/ai_assistant)。

## v2.1 现状

- 发送链路已经从 Dock UI 中拆出，核心编排集中在 `AIRuntime`
- Prompt、上下文、规则、消息归一化已经模块化
- 规则系统支持内置规则、用户规则、项目规则、目录局部规则和 `@include`
- 会话存储具备结构化记忆、自动压缩和 schema 迁移
- Provider 通过 profile / adapter 抽象，支持 DeepSeek 与 OpenAI Compatible
- Apply 流程统一走 `ActionExecutor`，支持候选目标、diff 预览和高风险确认
- 项目索引、Git 摘要、脚本/选区上下文都会注入请求
- Context Ring 可以预估上下文占用并提示压缩风险

## 主要目录

```text
addons/ai_assistant/
  ai_assistant.gd
  ai_chat_renderer.gd
  ai_context_ring.gd
  ai_dock.gd
  ai_dock.tscn
  ai_net_client.gd
  ai_storage.gd
  actions/
  core/
  memory/
  net/
  project/
  prompt/
```

## 验证

本次版本已使用 Godot CLI 做过编辑器级加载验证：

```powershell
C:\Users\s1897\scoop\shims\godot.exe --headless --path E:\test --editor --quit
```

验证结果为通过，未出现新的脚本解析或编译错误。

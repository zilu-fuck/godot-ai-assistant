# Godot AI Assistant v2.2-dev

## v2.2 Runtime Upgrade

- Runtime now tracks clearer request stages and exposes a stable `request_id` in debug/preview output.
- Network requests can retry once on short failures, fall back from streaming to non-streaming, and preserve partial responses explicitly.
- AI Apply now stores rollback data so the latest AI change in the current session can be undone with conflict checks.
- Context selection now adds lightweight relevance boosts for the active file/selection, prompt-mentioned symbols or paths, Git-oriented prompts, and project-structure questions.
- The regression checklist in [tasks/runtime_adaptation_checklist.md](/E:/test/tasks/runtime_adaptation_checklist.md) now covers state transitions, retry/fallback, partial responses, relevance ranking, and undo.

## v2.2 Validation

- Runtime/apply/undo validation script: [v22_validation.gd](/E:/test/test/v22_validation.gd)
- Dock/UI validation script: [ui_validation.gd](/E:/test/test/ui_validation.gd)
- One-shot validation runner: [run_v22_validations.ps1](/E:/test/test/run_v22_validations.ps1)

```powershell
powershell -ExecutionPolicy Bypass -File E:\test\test\run_v22_validations.ps1
```

这是一个面向 Godot 4 编辑器的 AI 编码助手插件项目，核心交付目录是 [addons/ai_assistant](E:/test/addons/ai_assistant)。

如果你是第一次接手这个仓库，优先看：

- [tasks/必看.md](E:/test/tasks/必看.md)
- [tasks/v2.0.1更新报告.md](E:/test/tasks/v2.0.1更新报告.md)

## 项目定位

这个插件不是普通聊天窗口，而是一个直接嵌入 Godot 编辑器工作流的 AI 助手。

它会结合这些上下文来辅助开发：

- 当前脚本
- 当前选区
- 当前场景路径
- 项目文件索引
- Git 摘要
- 规则文件
- 会话历史与结构化记忆

## v2.0.1 当前能力

- 多会话聊天与本地持久化
- 流式输出、手动停止与错误回显
- 当前脚本 / 选区上下文注入
- 项目索引与 Git 摘要注入
- 分层规则系统与 `@include`
- 结构化记忆与自动压缩
- Provider profile / adapter 抽象
- 统一的 `ActionExecutor` 代码应用链路
- 候选目标、diff 预览与高风险二次确认
- Context Ring 上下文占用预估

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

## 版本信息

- 插件版本：`2.0.1`
- 插件配置文件：[plugin.cfg](E:/test/addons/ai_assistant/plugin.cfg)
- 当前版本重点：完成运行时、规则、记忆、provider、动作执行分层，并补齐 v2.0.1 文档

## 验证

本次版本已使用下面的 Godot CLI 做过编辑器级加载验证：

```powershell
C:\Users\s1897\scoop\shims\godot.exe --headless --path E:\test --editor --quit
```

验证结果：

- 编辑器可正常加载项目
- 插件脚本未出现新的 parse error / compile error
- Git 文本检查已通过

## 说明

- `addons/ai_assistant` 是真正需要关注和交付的插件目录
- `test/` 目录主要是测试和演示内容
- 更完整的交接说明见 [tasks/必看.md](E:/test/tasks/必看.md)

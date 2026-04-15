# Godot AI Assistant

这是一个面向 Godot 4 编辑器的 AI 助手插件，当前实现已经完成 1-8 阶段的首轮重构落地：保留原有 Dock 交互外壳，同时把运行时链路拆成了独立模块，方便后续继续扩展 provider、动作执行和更强的 agent 能力。

## 当前能力

- 多会话聊天与本地持久化
- 流式输出与错误回传
- 当前脚本 / 选区上下文注入
- 内置规则 + 用户规则 + 项目规则 + 本地目录规则加载
- `@include` 规则展开与循环引用报错
- 结构化会话记忆与自动压缩
- Provider profile / adapter 抽象
- `Apply` 动作统一走 `ActionExecutor`
- 项目文件索引与 Git 状态摘要注入

## 当前目录结构

```text
addons/ai_assistant/
  ai_assistant.gd
  ai_chat_renderer.gd
  ai_dock.gd
  ai_dock.tscn
  ai_net_client.gd
  ai_storage.gd
  actions/
    ai_action_executor.gd
  core/
    ai_runtime.gd
  memory/
    ai_memory_manager.gd
  net/
    ai_provider_adapter.gd
    ai_provider_profiles.gd
  project/
    ai_git_context.gd
    ai_project_indexer.gd
  prompt/
    ai_context_builder.gd
    ai_message_normalizer.gd
    ai_prompt_builder.gd
    ai_rules_loader.gd
```

## 模块职责

- `ai_dock.gd`
  负责 UI 状态、会话切换、按钮事件与渲染协调。
- `core/ai_runtime.gd`
  负责发送编排、上下文收集、规则加载、provider 请求构建。
- `prompt/`
  负责规则、上下文、消息归一化与最终 prompt 组装。
- `memory/ai_memory_manager.gd`
  负责结构化记忆、自动压缩和摘要导出。
- `net/ai_provider_profiles.gd`
  维护模型配置和能力声明。
- `net/ai_provider_adapter.gd`
  把统一 runtime request 转成具体 provider payload。
- `actions/ai_action_executor.gd`
  统一处理插入、替换和预览确认后的应用动作。
- `project/`
  提供项目索引和 Git 摘要，作为系统上下文的一部分注入请求。

## 如何新增模型

如果是同类兼容接口，优先在 `addons/ai_assistant/net/ai_provider_profiles.gd` 里新增条目：

```gdscript
"your-model-id": {
	"name": "显示名称",
	"provider": "openai_compatible",
	"default_url": "https://api.openai.com/v1/chat/completions",
	"use_system_role": true,
	"temperature": 0.7,
	"supports_system_role": true,
	"supports_reasoning_delta": false,
	"supports_streaming": true,
	"supports_tool_calls": true,
	"supports_cache_hints": false,
}
```

如果是新的 payload 格式，再补 `addons/ai_assistant/net/ai_provider_adapter.gd` 的适配分支即可。

## 阶段进度

- 阶段 1：发送链路从 `ai_dock.gd` 拆到 `AIRuntime`
- 阶段 2：Prompt / Context / Message Normalizer 模块化
- 阶段 3：规则系统与 `@include` 支持
- 阶段 4：结构化记忆与自动压缩
- 阶段 5：Provider profile / adapter 抽象
- 阶段 6：统一动作执行器初版
- 阶段 7：项目索引与 Git 上下文注入
- 阶段 8：UI 调试信息收口与 README 对齐

## 当前限制

- 还没有完整的工具调用协议层
- `ActionExecutor` 目前只覆盖插入和替换选区
- 本环境未集成 `godot` CLI，暂时只能做静态脚本检查，无法在这里直接跑编辑器级自动验证

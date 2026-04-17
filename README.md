# Godot AI Assistant v2.2

这是一个面向 Godot 4 编辑器的 AI 编码助手插件。它以内嵌 Dock 的形式工作，能够结合项目上下文、规则、记忆和代码应用流程，在真正修改文件之前先让用户查看和确认 AI 生成结果。

## v2.2 更新重点

- Runtime 请求流程改为明确的阶段状态，而不是单一的忙碌标记。
- 每次请求都会生成稳定的 `request_id`，并提供更完整的调试信息。
- 网络层支持短暂失败单次重试、从流式降级到非流式，以及部分响应保留。
- AI Apply 现在会记录回滚信息，支持撤销当前会话中的最近一次 AI 改动。
- 场景创建已接入统一的预览、确认和回滚流程，配套脚本也会一起处理。
- 上下文选择新增轻量相关性排序，会优先考虑当前文件、当前选区、提示词中提到的路径或符号、最近编辑内容和 Git 相关请求。

## 主要能力

- 多会话聊天与本地持久化
- 基于当前脚本、选区、场景、项目索引、Git 摘要、规则和会话记忆的上下文构建
- 带预算控制和可解释性的 Prompt 构建
- 面向 OpenAI 兼容接口的 Provider Profile / Adapter 抽象
- 先预览再应用的代码落地流程，包含目标解析、Diff 预览和高风险二次确认
- `.tscn` 场景创建和配套脚本生成
- 当前会话最近一次 AI 改动的撤销入口

## 目录结构

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

其中 `addons/ai_assistant` 是实际交付的插件目录，其余内容主要用于项目维护和开发协作。

## 快速开始

1. 使用 Godot 4 打开本项目。
2. 在 `Project Settings -> Plugins` 中启用插件。
3. 打开 `AI助手` Dock。
4. 配置 API URL、API Key 和模型名称。
5. 发送请求，查看生成的计划或 Diff，并在确认后应用改动。

## 发布前验证

建议至少执行下面两项检查：

```powershell
godot --headless --path E:\test --editor --quit-after 1
git diff --check
```

## 版本信息

- 插件版本：`2.2`
- 插件配置文件：`addons/ai_assistant/plugin.cfg`

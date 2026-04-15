# Claude Code Runtime 启发在当前项目中的最小落地方案

## 文档目标

本文档用于总结：在当前 `Godot AI Assistant` 项目中，哪些 Claude Code 的设计思路值得借鉴，哪些暂时不该引入，以及一版适合当前仓库体量的最小落地方案。

本文档基于以下假设：

- 保留当前插件入口、Dock UI 和现有可用功能。
- 优先提升 `runtime` 稳定性、上下文质量和动作安全性。
- 暂不追求一步到位做成完整多工具、多 Agent 平台。

## 当前项目判断

当前项目并不是“只有一坨 prompt”的状态，实际上已经具备一套轻量 runtime 雏形：

- `AIRuntime` 已承担请求编排职责。
- `AIPromptBuilder` 已开始做 prompt 分层。
- `AIRulesLoader` 已支持分层规则与 `@include`。
- `AIMemoryManager` 已支持结构化记忆和自动压缩。
- `AIProviderProfiles` / `AIProviderAdapter` 已建立 provider 抽象。
- `AIActionExecutor` 已初步统一代码应用动作。

因此，最值得学习 Claude Code 的地方，不是继续堆 prompt，而是继续把现有模块做成一套更可治理的 runtime。

## 核心结论

最适合当前项目直接借鉴的能力，按优先级排序如下：

1. 上下文治理
2. 动作权限控制
3. 显式 runtime 状态机
4. 请求可观测性
5. 进一步细化 prompt 分层

不建议当前阶段优先引入的能力如下：

- 完整 tool-calling schema
- 多 Agent 自治循环
- AST 级项目分析
- 面向大量 provider 的超宽兼容层
- 厂商专用 prompt cache 技巧

## 各能力的适配判断

### 1. Prompt 分层

适配度：高

当前项目已经做了基础分层，但仍有继续细化空间。现在的 `system sections` 中混入了规则、动态环境信息、Git 摘要和项目摘要，后续调试成本仍然偏高。

建议继续拆成以下几层：

- `stable_system_rules`
- `dynamic_system_context`
- `runtime_user_context`
- `session_memory`
- `history`
- `action_or_intent_hint`

目标不是增加复杂度，而是让后续能够明确回答“这轮输出到底受哪一层影响”。

### 2. 上下文治理

适配度：最高

这是当前项目最值得直接借鉴的部分。Claude Code 的价值并不在“塞更多上下文”，而在“控制上下文质量”。

当前项目已有：

- 历史消息裁剪
- 代码上下文截断
- 自动压缩会话记忆
- 项目摘要和 Git 摘要注入

当前缺口在于：

- 没有按来源做预算控制
- 没有统一上下文优先级
- 没有明确记录哪些上下文被保留、哪些被裁掉
- 长脚本和项目摘要仍可能在每轮请求中重复注入

建议最先补齐以下能力：

- `per-source budget`
- `context item priority`
- `context collapse`
- `context manifest`

### 3. Agent Loop / Runtime Loop

适配度：高

当前项目已有 `AIRuntime`，但还不是完整的会话级状态机。请求准备、流式中、停止、失败、待确认动作等状态仍然分散在 Dock 层和网络层之间。

建议不要直接做“自动多轮 Agent”，而是先补一个显式的最小状态机：

- `idle`
- `preparing`
- `streaming`
- `awaiting_action_confirmation`
- `completed`
- `failed`
- `stopped`

这样做的目标不是“更高级”，而是避免后续继续把 runtime 决策堆回 `ai_dock.gd`。

### 4. 工具系统

适配度：中

Claude Code 的完整工具系统很强，但对当前项目来说，全面照搬会明显过早设计。

当前项目更适合把已有能力继续当作“受控动作”演进，而不是立刻暴露成完整 tool schema。当前阶段的重点应是：

- 统一动作类型
- 建立动作权限 gate
- 统一预览和确认逻辑

而不是：

- 向模型暴露完整工具协议
- 做复杂工具池排序、去重、缓存稳定性

### 5. 权限设计

适配度：最高

这部分和当前项目高度契合，因为项目已经具备直接修改编辑器内容的能力。当前的权限边界主要体现在“替换选区前要预览”，但这还不够。

建议引入最小权限模型：

- `explain_only`
- `suggest_code`
- `insert_at_caret`
- `replace_selection`
- `show_diff_only`

同时加入明确 gate：

- `replace_selection` 必须预览确认
- `rewrite_file` 若未来引入，默认必须人工确认
- 普通解释类回答不应触发 Apply
- 高风险动作必须写入动作日志

### 6. Provider 抽象

适配度：中高

这部分当前项目已经做得比较合理，足以支持近期演进。Claude Code 的启发更多是提醒：provider abstraction 要服务于 runtime，而不是反过来主导架构。

当前阶段建议：

- 保持 `profile + adapter` 双层结构
- 仅抽象真实存在的差异
- 不为未知 provider 预留过多复杂接口

## 建议的最小落地范围

首批改造建议只覆盖下面四个模块：

1. `addons/ai_assistant/prompt/ai_context_builder.gd`
2. `addons/ai_assistant/prompt/ai_prompt_builder.gd`
3. `addons/ai_assistant/core/ai_runtime.gd`
4. `addons/ai_assistant/actions/ai_action_executor.gd`

这四处改完，用户体验会明显更接近“runtime 驱动的编辑器助手”，且不会把项目拖入过度重构。

## 分阶段实施方案

### 阶段 1：上下文预算化

目标：把上下文从“字符串拼接”升级为“带来源和优先级的 context items”。

建议修改：

- `ai_context_builder.gd`
- `ai_prompt_builder.gd`
- `ai_runtime.gd`

建议做法：

- `AIContextBuilder` 返回结构化 `items`
- 每个 item 包含：
  - `kind`
  - `priority`
  - `text`
  - `truncated`
  - `source`
- `AIPromptBuilder` 根据预算和优先级挑选上下文
- `AIRuntime` 记录本轮实际注入项和被裁剪项

建议的上下文种类：

- `script_text`
- `selection_text`
- `session_memory`
- `git_summary`
- `project_map`

验收标准：

- 长对话中请求体增长更可控
- 长脚本不会在每轮都整段注入
- 能看见本轮到底用了哪些上下文来源

### 阶段 2：动作权限化

目标：把“能否应用代码”从 UI 习惯升级为 runtime 明确规则。

建议修改：

- `ai_action_executor.gd`
- `ai_dock.gd`

建议做法：

- 为动作补充 `intent` / `risk_level` / `requires_confirmation`
- 增加统一的 `can_execute_action()` 判断
- 将“解释”“展示 diff”“替换选区”“插入光标处”明确区分

首批动作类型建议限制为：

- `explain_only`
- `show_diff_only`
- `insert_at_caret`
- `replace_selection`

验收标准：

- 回答只是解释时，不显示可执行的 Apply
- 需要改代码时，预览和执行边界清晰
- 动作日志能反映本次修改属于哪一类风险

### 阶段 3：runtime 状态显式化

目标：让请求生命周期可追踪，减少 `ai_dock.gd` 内的隐式状态。

建议修改：

- `ai_runtime.gd`
- `ai_dock.gd`
- `ai_net_client.gd`

建议做法：

- 在 runtime 中维护统一状态字段
- Dock 层只消费状态，不做额外业务推断
- 将停止、失败、完成、待确认动作视为不同状态，而非 UI 分支逻辑

验收标准：

- 停止生成、请求失败、待确认动作在 UI 上能明确区分
- 后续新增动作或工具时，不需要继续把状态判断塞进 Dock

### 阶段 4：请求可观测性增强

目标：减少调试黑盒感，提升 prompt / context / memory 问题定位效率。

建议修改：

- `ai_runtime.gd`
- `ai_dock.gd`

建议在 preview 中增加：

- 最终 message 数量
- 每类 context 的字符数
- 被裁剪的 context 列表
- 是否触发自动压缩
- 本轮加载的规则来源
- 当前 provider 能力摘要

验收标准：

- 能快速判断是 prompt 问题、context 问题还是 provider payload 问题
- 调整上下文策略时能直接对比改动效果

## 推荐的数据结构方向

### Context Item

建议引入统一的上下文项结构：

```gdscript
{
  "kind": "script_text",
  "source": "res://test/login.gd",
  "priority": 100,
  "text": "...",
  "truncated": false
}
```

### Action Descriptor

建议引入统一动作描述：

```gdscript
{
  "type": "replace_selection",
  "label": "Replace Selection",
  "content": "...",
  "intent": "modify_code",
  "risk_level": "medium",
  "requires_confirmation": true
}
```

### Request Preview

建议扩展调试预览：

```gdscript
{
  "model": "...",
  "profile": {...},
  "rules": {...},
  "memory": {...},
  "context_manifest": [...],
  "dropped_context_items": [...],
  "payload": {...},
  "auto_compact": {...}
}
```

## 当前阶段不建议优先做的事

为避免过早设计，以下事项建议暂缓：

- 完整 tool-calling API 协议
- 多 Agent 并发或自治调度
- 完整 AST / symbol 索引
- 复杂 provider fallback 编排
- 面向厂商缓存的 prompt 优化
- UI 侧大规模重做

这些方向并非不重要，而是不应抢占当前最关键的 runtime 治理工作。

## 建议的首个改造批次

如果只做一轮小版本迭代，建议范围如下：

1. 让 `AIContextBuilder` 返回结构化 context items
2. 让 `AIPromptBuilder` 根据预算挑选和裁剪上下文
3. 让 `AIRuntime` 记录完整 request preview 和 context manifest
4. 让 `AIActionExecutor` 加入最小权限 gate

这一批改造的特点是：

- 改动集中
- 回报明确
- 风险可控
- 不要求重写整个插件

## 最终验收标准

当以下条件大体满足时，可以认为这轮“借鉴 Claude Code runtime”的改造达标：

- 连续对话 10 轮后，请求体不会明显失控膨胀
- 长脚本不会在每轮都整段重复注入
- 用户能够看见本轮使用了哪些上下文来源
- 解释类回答不会误触发代码应用
- 高风险动作具有清晰确认边界
- `ai_dock.gd` 不再继续承担更多 runtime 决策

## 一句话总结

当前项目最该学习 Claude Code 的，不是“更长的 prompt”，而是“更受控的 runtime”。

在现阶段，最划算的路径不是做大而全 agent，而是先把：

- 上下文治理
- 动作权限
- runtime 状态
- 请求可观测性

这四件事做扎实。

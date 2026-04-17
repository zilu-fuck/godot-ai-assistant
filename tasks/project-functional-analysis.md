# 项目功能与实现逻辑分析

本文把前面的功能分析、模块职责和运行逻辑整理到一个文档里，并为每一项补充“实现位置”和“伪代码”。

## 总体结论

这个项目本质上是一个基于 Bun 的终端 AI 编码助手 CLI。

它不是单纯的聊天程序，而是一套完整的代理式系统，包含这些层次：

1. 启动与模式分流
2. CLI 参数解析与初始化
3. REPL 交互界面
4. 上下文与记忆注入
5. 模型调用与多轮 agent loop
6. 工具系统
7. 权限与安全边界
8. MCP 扩展
9. 技能与插件扩展
10. 会话状态、任务和恢复

## 先看一条总调用链

```text
src/entrypoints/cli.tsx
  -> src/main.tsx
    -> setup()
    -> getCommands()
    -> getTools()
    -> 加载 agents / plugins / skills / MCP
    -> showSetupScreens()
    -> launchRepl() 或 headless print 模式
      -> query()
        -> services/api/claude.ts
        -> 模型流式输出
        -> 工具执行
        -> 工具结果回传
        -> 下一轮模型调用
```

## 重要前提

当前仓库是“外部构建”语义。

`src/entrypoints/cli.tsx` 中把 `feature()` 固定为了 `false`，因此很多 Anthropic 内部功能虽然代码还在，但默认不会在这个构建里启用。

这意味着：

1. 代码里看到的能力范围，大于默认外部构建实际启用的能力范围。
2. 阅读时要区分“有代码”与“当前生效”。

---

## 1. 启动与模式分流

### 功能说明

程序入口负责做最轻量的启动判断，尽可能避免一上来就加载整个应用。

它主要完成：

1. 注入运行时宏和构建常量
2. 处理 `--version` 这类 fast path
3. 处理 Chrome/MCP、bridge、daemon、后台 session 等特殊入口
4. 如果不是特殊模式，再进入真正的主程序

### 关键文件

1. `src/entrypoints/cli.tsx`

### 实现逻辑

入口文件先定义 `feature()` polyfill 和全局常量，再检查参数：

1. 如果只是看版本号，直接输出后退出
2. 如果是某个特殊子入口，动态导入对应模块并运行
3. 否则再动态导入 `src/main.tsx`

这样做的好处是冷启动更快，而且不同模式的依赖不会无谓加载。

### 伪代码

```text
function cliEntrypoint():
    installRuntimePolyfills()
    args = process.argv[2:]

    if args == ["--version"] or ["-v"]:
        print(version)
        return

    if args matches chrome_mcp_mode:
        import chrome_mcp_module
        run chrome_mcp_module
        return

    if args matches bridge_mode and feature_enabled:
        import bridge_module
        run bridge_module
        return

    if args matches daemon_mode and feature_enabled:
        import daemon_module
        run daemon_module
        return

    import main_module
    run main_module.main()
```

---

## 2. CLI 初始化与应用装配

### 功能说明

`main.tsx` 是真正的主装配中心。

它负责：

1. 解析命令行参数
2. 初始化全局设置和环境
3. 预加载命令、agent、plugins、skills
4. 连接 MCP
5. 计算 permission mode、model、session 等关键运行参数
6. 进入 REPL 或 headless 模式

### 关键文件

1. `src/main.tsx`
2. `src/setup.ts`

### 实现逻辑

主程序会在 setup 前后并行做很多事情：

1. 激活 bundled plugins 和 bundled skills
2. 调用 `setup()` 建立运行环境
3. 并行加载 commands 和 agents
4. 在需要时预热 `getSystemContext()` 和 `getUserContext()`
5. 在 headless 模式下组装初始状态并等待 MCP 连接完成
6. 在 interactive 模式下进入 setup screens 和 REPL

这里的重点不是“顺序执行”，而是大量并行预热，以降低启动耗时。

### 伪代码

```text
function main():
    parseCliOptions()
    determineInteractiveOrHeadless()
    determinePermissionMode()
    determineModel()

    maybeActivateBundledPlugins()
    maybeActivateBundledSkills()

    setupPromise = setup(cwd, permissionMode, worktreeOptions, sessionOptions)
    commandsPromise = getCommands(cwd)
    agentsPromise = getAgentDefinitions(cwd)

    await setupPromise

    commands, agents = await Promise.all(commandsPromise, agentsPromise)

    if headless_mode:
        prefetchSystemContext()
        prefetchUserContext()
        connectMcpServers()
        buildHeadlessAppState()
        runHeadlessFlow()
    else:
        showSetupScreens()
        launchRepl()
```

---

## 3. 命令系统

### 功能说明

项目里的“斜杠命令”不是单一列表，而是一个运行时拼装出来的命令体系。

它由四部分组成：

1. 内建命令
2. 技能目录生成的命令
3. 插件提供的命令
4. 工作流与动态技能命令

### 关键文件

1. `src/commands.ts`
2. `src/skills/loadSkillsDir.ts`
3. `src/utils(1)/plugins/loadPluginCommands.ts`

### 实现逻辑

`commands.ts` 先定义内建命令集合 `COMMANDS()`，然后：

1. 通过 `getSkills()` 拿到 skill dir commands、plugin skills、bundled skills
2. 通过 `getPluginCommands()` 拿到插件命令
3. 通过 `getWorkflowCommands()` 拿到工作流命令
4. 用 `loadAllCommands()` 合并成完整命令池
5. 用 `meetsAvailabilityRequirement()` 和 `isCommandEnabled()` 做过滤
6. 最后把动态技能插到合适位置

### 伪代码

```text
function getCommands(cwd):
    allBuiltin = COMMANDS()
    skillCommands = loadSkillDirCommands(cwd)
    pluginCommands = loadPluginCommands()
    pluginSkills = loadPluginSkills()
    workflowCommands = loadWorkflowCommands(cwd)
    bundledSkills = getBundledSkills()

    allCommands = merge(
        bundledSkills,
        skillCommands,
        workflowCommands,
        pluginCommands,
        pluginSkills,
        allBuiltin
    )

    filtered = []
    for command in allCommands:
        if availability_ok(command) and is_enabled(command):
            filtered.append(command)

    dynamicSkills = getDynamicSkills()
    return insertDynamicSkills(filtered, dynamicSkills)
```

---

## 4. REPL 终端界面

### 功能说明

交互式模式不是一个简单的输入输出循环，而是一个 React/Ink 驱动的终端 UI。

它承载：

1. 消息展示
2. Prompt 输入
3. 权限弹窗
4. MCP/插件/IDE 集成
5. 后台任务和 agent 视图
6. 通知、状态栏、辅助面板

### 关键文件

1. `src/replLauncher.tsx`
2. `src/screens/REPL.tsx`
3. `src/state/AppStateStore.ts`

### 实现逻辑

`launchRepl()` 只做一件事：把 `App` 和 `REPL` 挂起来。

真正的逻辑在 `REPL.tsx`：

1. 从 AppState 中读取 permission context、MCP、plugins、tasks 等状态
2. 计算本地工具集合 `localTools`
3. 合并 `initialTools + localTools + mcp.tools`
4. 合并本地命令、插件命令和 MCP 命令
5. 在用户提交 prompt 时构造 `toolUseContext`
6. 并行准备 system prompt、user context、system context
7. 调用 `query()`
8. 按流式事件不断刷新消息列表

### 伪代码

```text
function launchRepl():
    render(
        App(
            REPL(...)
        )
    )

function REPL():
    appState = useAppState()
    localTools = getTools(appState.toolPermissionContext)
    mergedTools = mergeTools(localTools, initialTools, appState.mcp.tools)
    mergedCommands = mergeCommands(localCommands, pluginCommands, mcpCommands)

    onSubmit(prompt):
        toolUseContext = buildToolUseContext(currentMessages, mergedTools, mcpClients)
        defaultSystemPrompt = getSystemPrompt(mergedTools, model, extraDirs, mcpClients)
        userContext = getUserContext()
        systemContext = getSystemContext()
        effectiveSystemPrompt = buildEffectiveSystemPrompt(...)

        for event in query(...):
            applyEventToMessageList(event)
            refreshUI()
```

---

## 5. AppState 状态管理

### 功能说明

整个 REPL 的状态非常多，所以项目把它集中放进 `AppState`。

这里统一管理：

1. 当前工具权限上下文
2. 任务与子代理状态
3. MCP 客户端、工具、命令、资源
4. 插件启用状态和错误
5. 文件历史、归因、todo
6. bridge/remote 状态
7. 通知、elicitation、prompt suggestion 等

### 关键文件

1. `src/state/AppStateStore.ts`
2. `src/state/store.ts`

### 实现逻辑

思路是：

1. 定义一份全局状态结构
2. 所有 UI 子模块读写这份状态
3. REPL 根据这份状态计算工具池、命令池和显示内容
4. MCP、plugins、permissions、tasks 都只是在更新 AppState 的不同片段

### 伪代码

```text
type AppState:
    settings
    toolPermissionContext
    tasks
    mcp = { clients, tools, commands, resources }
    plugins = { enabled, disabled, commands, errors }
    fileHistory
    notifications
    todos
    remoteStatus
    bridgeStatus
    ...

function updateAppState(patch):
    state = merge(state, patch)
    notifySubscribers()
```

---

## 6. 上下文注入

### 功能说明

这个项目不会把用户输入原封不动发给模型，而是会先构造上下文。

上下文主要分两类：

1. System Context
2. User Context

### 关键文件

1. `src/context.ts`

### 实现逻辑

`getSystemContext()`：

1. 判断当前目录是不是 Git 仓库
2. 读取当前分支、主分支、`git status`、最近提交、git 用户名
3. 组装成一段系统上下文文本

`getUserContext()`：

1. 读取 `CLAUDE.md` 体系里的内容
2. 加上当前日期
3. 缓存结果，避免每轮都重新扫盘

### 伪代码

```text
function getSystemContext():
    if not git_repo or git_instructions_disabled:
        return {}

    branch = git branch
    mainBranch = detect default branch
    status = git status --short
    recentCommits = git log -n 5
    userName = git config user.name

    return {
        gitStatus: format(branch, mainBranch, status, recentCommits, userName)
    }

function getUserContext():
    if claude_md_disabled:
        return { currentDate: today() }

    memoryFiles = getMemoryFiles()
    claudeMd = getClaudeMds(memoryFiles)

    return {
        claudeMd: claudeMd,
        currentDate: today()
    }
```

---

## 7. 记忆与规则系统

### 功能说明

`CLAUDE.md` 系统是项目上下文工程的核心。

它实现了四层记忆：

1. Managed
2. User
3. Project
4. Local

还支持：

1. `.claude/rules/*.md`
2. 条件规则
3. `@include`
4. 外部 include 风险提示
5. 额外目录注入

### 关键文件

1. `src/utils(1)/claudemd.ts`

### 实现逻辑

`getMemoryFiles()` 会：

1. 先读 Managed 和 User 级别文件
2. 再从当前目录一路向上遍历到根目录
3. 在每层尝试读取 `CLAUDE.md`、`.claude/CLAUDE.md`、`.claude/rules/*.md`、`CLAUDE.local.md`
4. 对文件内容做 frontmatter 解析和 include 展开
5. 用 `processedPaths` 去重

### 伪代码

```text
function getMemoryFiles(forceIncludeExternal = false):
    result = []
    processed = set()

    includeExternal = forceIncludeExternal or config.externalApproved

    result += processMemoryFile(managedClaudeMd, type="Managed")
    result += processRulesDir(managedRulesDir, type="Managed")

    if userSettingsEnabled:
        result += processMemoryFile(userClaudeMd, type="User")
        result += processRulesDir(userRulesDir, type="User")

    dirs = walkFromCwdUpToRoot()

    for dir in reverse(dirs):
        if projectSettingsEnabled:
            result += processMemoryFile(dir/CLAUDE.md, type="Project")
            result += processMemoryFile(dir/.claude/CLAUDE.md, type="Project")
            result += processRulesDir(dir/.claude/rules, type="Project")

        if localSettingsEnabled:
            result += processMemoryFile(dir/CLAUDE.local.md, type="Local")

    if additionalDirectoryClaudeMdEnabled:
        for extraDir in additionalDirs:
            result += process extra dir memory files

    return result

function processMemoryFile(path, type):
    if file_not_exists:
        return []
    content = read_file(path)
    content = resolve_includes(content)
    content, globs = parse_frontmatter(content)
    return [{ path, type, content, globs }]
```

---

## 8. 工具系统

### 功能说明

工具系统是项目的核心能力面。

项目把“AI 可以动手做的事情”统一抽象成 Tool。

内建工具包括：

1. BashTool
2. FileReadTool
3. FileEditTool
4. FileWriteTool
5. NotebookEditTool
6. WebFetchTool
7. WebSearchTool
8. AgentTool
9. AskUserQuestionTool
10. Todo/Task/MCP 相关工具

### 关键文件

1. `src/tools.ts`
2. `src/Tool.ts`
3. `src/tools/<ToolName>/...`

### 实现逻辑

`getAllBaseTools()` 定义当前环境可能拥有的全部基础工具。

`getTools(permissionContext)` 会：

1. 先处理 simple mode
2. 根据 deny rules 去掉禁止工具
3. 在 REPL 模式下隐藏 primitive tools
4. 只保留 `isEnabled()` 为真的工具

`assembleToolPool()` 再把 built-in tools 和 MCP tools 合并。

### 伪代码

```text
function getAllBaseTools():
    return [
        AgentTool,
        BashTool,
        FileReadTool,
        FileEditTool,
        FileWriteTool,
        NotebookEditTool,
        WebFetchTool,
        WebSearchTool,
        AskUserQuestionTool,
        ...
    ] + feature_gated_tools

function getTools(permissionContext):
    if simple_mode:
        return simple_tool_subset

    tools = getAllBaseTools()
    tools = removeSpecialInternalTools(tools)
    tools = filterByDenyRules(tools, permissionContext)

    if repl_mode:
        tools = hidePrimitiveToolsIfReplEnabled(tools)

    return [tool for tool in tools if tool.isEnabled()]

function assembleToolPool(permissionContext, mcpTools):
    builtin = getTools(permissionContext)
    allowedMcp = filterByDenyRules(mcpTools, permissionContext)
    return dedupe_and_sort(builtin + allowedMcp)
```

---

## 9. 查询主循环与 agent loop

### 功能说明

`query.ts` 是整个项目最核心的逻辑文件。

它负责：

1. 把上下文和历史消息发给模型
2. 流式接收输出
3. 识别工具调用
4. 执行工具
5. 把工具结果回传模型
6. 在需要时继续下一轮
7. 处理压缩、max token 恢复、终止钩子等

### 关键文件

1. `src/query.ts`

### 实现逻辑

`query()` 会创建跨轮次的 `State`：

1. `messages`
2. `toolUseContext`
3. `autoCompactTracking`
4. `maxOutputTokensRecoveryCount`
5. `pendingToolUseSummary`
6. `turnCount`
7. `transition`

然后进入 `queryLoop()`，每次循环做：

1. 计算当前要发给模型的消息
2. 调用模型流式接口
3. 收集 assistant messages 和 tool use blocks
4. 如果需要执行工具，就运行工具
5. 把 tool results 加回消息序列
6. 如果模型还需要 follow-up，就继续下一轮
7. 否则退出

### 伪代码

```text
function query(params):
    state = {
        messages,
        toolUseContext,
        autoCompactTracking,
        maxOutputTokensRecoveryCount,
        pendingToolUseSummary,
        turnCount = 1
    }

    while true:
        messagesForQuery = buildMessagesForThisTurn(state.messages, userContext, systemContext)

        stream = callModel(messagesForQuery, tools, modelOptions)

        assistantMessages = []
        toolUseBlocks = []
        toolResults = []

        for chunk in stream:
            message = normalizeChunk(chunk)
            yield message
            collectAssistantAndToolUse(message, assistantMessages, toolUseBlocks)

        if aborted:
            yield interruption_message
            return

        if recoverable_error:
            maybeCompactOrRetry()
            continue

        if toolUseBlocks not empty:
            for toolUpdate in runTools(toolUseBlocks):
                yield toolUpdate.message
                toolResults += normalizeToolResult(toolUpdate.message)

            state.messages = assistantMessages + toolResults
            state.turnCount += 1
            continue

        runStopHooks()
        return final_result
```

---

## 10. QueryEngine 高层封装

### 功能说明

`QueryEngine` 是对 `query()` 的更高层封装。

它面向的是：

1. SDK/headless 场景
2. 多轮会话持久化
3. 消息和权限拒绝记录
4. 更稳定的提交接口

### 关键文件

1. `src/QueryEngine.ts`

### 实现逻辑

它把会话级状态收拢到类实例中：

1. `mutableMessages`
2. `abortController`
3. `permissionDenials`
4. `readFileState`
5. `totalUsage`

对外暴露的入口是 `submitMessage()`：

1. 清理本轮状态
2. 包装 `canUseTool` 以记录权限拒绝
3. 处理用户输入
4. 调用底层 `query()`
5. 逐步产出 SDK 消息
6. 在合适节点 flush session storage

### 伪代码

```text
class QueryEngine:
    constructor(config):
        self.config = config
        self.mutableMessages = initialMessages
        self.abortController = new AbortController()
        self.permissionDenials = []
        self.readFileState = readFileCache
        self.totalUsage = emptyUsage()

    function submitMessage(prompt):
        wrappedCanUseTool = wrap(config.canUseTool, recordPermissionDenials)

        processedInput = processUserInput(prompt, currentMessages, commands, tools)

        for event in query({
            messages: self.mutableMessages + processedInput,
            canUseTool: wrappedCanUseTool,
            ...
        }):
            yield mapToSdkMessage(event)
            updateMutableState(event)

        flushSessionStorageIfNeeded()
```

---

## 11. 模型接入层

### 功能说明

项目不是只支持 Anthropic 直连。

它支持：

1. Anthropic direct
2. AWS Bedrock
3. Azure Foundry
4. Google Vertex

### 关键文件

1. `src/services/api/client.ts`

### 实现逻辑

`getAnthropicClient()` 会：

1. 根据环境变量判断当前 provider
2. 处理 OAuth / API key / cloud credentials
3. 构造统一的 default headers、timeout、proxy fetch
4. 返回不同 provider 对应的 Anthropic client 包装实例

### 伪代码

```text
function getAnthropicClient(options):
    headers = {
        x-app: "cli",
        user-agent,
        session-id,
        custom-headers,
        remote-headers
    }

    refreshOAuthIfNeeded()

    if provider == "bedrock":
        credentials = refreshAwsCredentialsIfNeeded()
        return new AnthropicBedrock(headers, region, credentials)

    if provider == "foundry":
        tokenProvider = buildAzureAdProviderIfNeeded()
        return new AnthropicFoundry(headers, tokenProvider)

    if provider == "vertex":
        refreshGcpCredentialsIfNeeded()
        googleAuth = buildGoogleAuth()
        return new AnthropicVertex(headers, region, googleAuth)

    return new AnthropicDirect(headers, apiKey or oauthToken)
```

---

## 12. 流式调用、重试与 fallback

### 功能说明

真正调用模型并处理流式响应的地方在 `services/api/claude.ts`。

这里做了很多工程化增强：

1. `withRetry`
2. request id 追踪
3. streaming watchdog
4. stall 检测
5. streaming 失败后 fallback 到 non-streaming

### 关键文件

1. `src/services/api/claude.ts`
2. `src/services/api/withRetry.ts`

### 实现逻辑

核心流程是：

1. 用 `withRetry()` 包一层 client 创建与请求发送
2. 调用 `anthropic.beta.messages.create(..., stream: true)`
3. 在流式读取过程中重置 idle timer
4. 如果长时间没 chunk，就主动 abort
5. 如果流式失败且允许 fallback，就切到 non-streaming request

### 伪代码

```text
function callModelStreaming(options):
    generator = withRetry(
        getClient,
        sendStreamingRequest
    )

    stream = await generator.next_final_value()

    startIdleWatchdog()

    try:
        for part in stream:
            resetIdleWatchdog()
            yield convertPartToEvent(part)
    catch streamingError:
        if fallback_disabled:
            throw streamingError

        markStreamingFallback()
        return executeNonStreamingRequest()
```

---

## 13. 权限系统与安全边界

### 功能说明

权限系统分为两层：

1. 启动前的 trust / onboarding / 审批
2. 运行时每次工具调用前的权限检查

### 关键文件

1. `src/interactiveHelpers.tsx`
2. `src/hooks/toolPermission/...`
3. `src/utils(1)/permissions/permissionSetup.ts`

### 实现逻辑

启动前：

1. 如果没 onboarding 过，先显示 onboarding
2. 如果工作区未 trust，显示 trust dialog
3. 审批 MCP server、外部 `CLAUDE.md` include
4. 必要时审批自定义 API key
5. 处理 bypass permissions 和 auto mode opt-in

运行时：

1. 工具调用先进入 permission context
2. 匹配 allow / deny 规则
3. 必要时弹出权限确认 UI
4. 用户确认后持久化规则更新

`permissionSetup.ts` 还会分析危险规则，防止 auto mode 获得过宽权限。

### 伪代码

```text
function showSetupScreens():
    if onboarding_not_done:
        showOnboarding()

    if workspace_not_trusted:
        showTrustDialog()

    approveMcpJsonServersIfNeeded()
    warnExternalClaudeMdIncludesIfNeeded()
    approveCustomApiKeyIfNeeded()
    handleBypassPermissionWarningIfNeeded()
    handleAutoModeOptInIfNeeded()

function canUseTool(tool, input):
    rule = matchPermissionRules(tool, input)

    if rule == deny:
        return reject

    if rule == allow:
        return allow

    return askUserForPermission()

function isDangerousAutoModeRule(toolName, ruleContent):
    if toolName == Bash and ruleContent matches interpreter_wildcards:
        return true
    if toolName == PowerShell and ruleContent matches shell_exec_patterns:
        return true
    if toolName == AgentTool:
        return true
    return false
```

---

## 14. MCP 扩展系统

### 功能说明

MCP 是这个项目的外部能力扩展层。

它支持：

1. `stdio`
2. SSE
3. streamable HTTP
4. WebSocket
5. SDK 内嵌式 MCP

并把远端 server 的：

1. tools
2. commands
3. resources
4. prompts

整合进应用内部。

### 关键文件

1. `src/services/mcp/client.ts`

### 实现逻辑

实现大致分成三部分：

1. 建立连接
2. 拉取 tools / resources / prompts
3. 把 MCP tools 包装成本地 `Tool` 结构

`ensureConnectedClient()` 保证服务已连通。  
`fetchToolsForClient()` 会调用 MCP 的 `tools/list`，然后为每个工具生成一个包装对象。  
`getMcpToolsCommandsAndResources()` 则把所有 server 的能力汇总并推入 AppState。

### 伪代码

```text
function ensureConnectedClient(client):
    if client is sdk_client:
        return client

    connected = connectToServer(client.name, client.config)
    if connected is not connected:
        throw not_connected_error
    return connected

function fetchToolsForClient(client):
    if client has no tools capability:
        return []

    result = client.request("tools/list")
    tools = []

    for remoteTool in result.tools:
        tools.append(
            wrapAsLocalTool(
                name = buildMcpToolName(client.name, remoteTool.name),
                schema = remoteTool.inputSchema,
                call = lambda args: callMcpTool(client, remoteTool, args)
            )
        )

    return tools

function getMcpToolsCommandsAndResources(onServerReady, configs):
    for each config in configs in parallel:
        client = connect(config)
        tools = fetchToolsForClient(client)
        commands = fetchCommandsForClient(client)
        resources = fetchResourcesForClient(client)
        onServerReady({ client, tools, commands, resources })
```

---

## 15. 技能系统

### 功能说明

技能系统让模型可以在会话中获得额外的“工作方法”与“指令模板”。

这里不仅有静态技能，还有：

1. 动态技能
2. 条件技能

条件技能会在操作到匹配路径后自动激活。

### 关键文件

1. `src/skills/loadSkillsDir.ts`

### 实现逻辑

核心逻辑是：

1. 扫描技能目录
2. 解析 frontmatter
3. 把普通技能直接注册成命令
4. 把带 `paths` 的技能先放进 `conditionalSkills`
5. 当文件操作发生时，用 `activateConditionalSkillsForPaths()` 检查是否命中
6. 命中的技能转移到 `dynamicSkills`

### 伪代码

```text
function loadSkillsFromDirectory(skillDir):
    skills = parseAllSkillFiles(skillDir)

    for skill in skills:
        if skill.has_paths_condition:
            conditionalSkills[skill.name] = skill
        else:
            registerSkillCommand(skill)

function activateConditionalSkillsForPaths(filePaths, cwd):
    activated = []

    for skill in conditionalSkills:
        if any(path_matches(skill.paths, filePaths, cwd)):
            dynamicSkills[skill.name] = skill
            remove skill from conditionalSkills
            activated.append(skill.name)

    return activated

function getDynamicSkills():
    return values(dynamicSkills)
```

---

## 16. 插件系统

### 功能说明

插件系统是技能系统之外的另一个扩展入口。

插件可以提供：

1. commands
2. skills
3. MCP servers
4. 安装状态和错误信息

### 关键文件

1. `src/utils(1)/plugins/loadPluginCommands.ts`
2. `src/hooks/useManagePlugins.ts`

### 实现逻辑

插件加载时会：

1. 读取启用插件列表
2. 并行扫描每个插件的 command 和 skill 目录
3. 去重并缓存结果
4. 把结果合并进 AppState 和 commands/tool pool

### 伪代码

```text
function getPluginSkills():
    plugins = loadEnabledPlugins()
    allSkills = []

    for plugin in plugins in parallel:
        pluginSkills = []

        if plugin.defaultSkillsPath exists:
            pluginSkills += loadSkillsFromDirectory(plugin.defaultSkillsPath)

        for extraPath in plugin.skillsPaths:
            pluginSkills += loadSkillsFromDirectory(extraPath)

        allSkills += pluginSkills

    return allSkills
```

---

## 17. 后台任务、子代理和会话内任务系统

### 功能说明

这个项目不是单线程“一问一答”，而是支持任务对象、子代理和后台执行的。

相关能力包括：

1. AgentTool
2. TaskOutputTool
3. TaskStopTool
4. 前台与后台 session
5. agent 名称注册和消息转发

### 关键文件

1. `src/tools/AgentTool/...`
2. `src/tasks/...`
3. `src/screens/REPL.tsx`

### 实现逻辑

整体思路是：

1. 主线程能创建子任务
2. 子任务有自己的消息流和状态
3. AppState 里统一维护 `tasks`
4. REPL 可以前台查看和切换任务
5. 某些通知还能被转入 background session 继续处理

### 伪代码

```text
function spawnAgentTask(prompt, config):
    taskId = createTaskRecord()
    appState.tasks[taskId] = pending_task
    startTaskLoop(taskId, prompt, config)

function startBackgroundSession(messages, queryParams):
    session = createBackgroundSession(messages, queryParams)
    runQueryInBackground(session)

function appendTaskOutput(taskId, message):
    appState.tasks[taskId].messages += message
```

---

## 18. 会话持久化与恢复

### 功能说明

这个项目会把会话写入 transcript，并支持恢复。

它保存的不只是消息，还包括：

1. content replacements
2. attribution snapshot
3. 文件历史
4. context collapse 信息
5. 会话标题、agent 设置、模式信息

### 关键文件

1. `src/utils(1)/sessionStorage.ts`
2. `src/utils(1)/conversationRecovery.ts`

### 实现逻辑

持久化：

1. 每轮对话和关键状态变化都写入 transcript
2. 工具结果替换、压缩、归因等也会记录
3. 通过 `flushSessionStorage()` 落盘

恢复：

1. `loadConversationForResume()` 找到对应 transcript
2. 反序列化消息
3. 处理旧版本 attachment 迁移
4. 过滤未闭合的 tool use
5. 恢复 skill 状态和 session metadata
6. 追加 resume hooks

### 伪代码

```text
function recordConversationEvent(event):
    append event to transcript

function flushSessionStorage():
    write buffered events to disk

function loadConversationForResume(source):
    log = loadTranscript(source)
    sessionId = extractSessionId(log)
    copyPlanForResume(log, sessionId)
    copyFileHistoryForResume(log)

    messages = deserializeMessages(log.messages)
    restoreSkillStateFromMessages(messages)
    hookMessages = processSessionStartHooks("resume", sessionId)

    return {
        messages: messages + hookMessages,
        sessionMetadata,
        snapshots,
        contentReplacements
    }
```

---

## 19. 从用户输入到最终回答的一次完整流程

### 过程说明

把所有模块串起来，一次完整交互大致是这样：

1. 用户在 REPL 输入一句话
2. REPL 生成 `toolUseContext`
3. 系统并行读取：
   1. system prompt
   2. user context
   3. system context
4. 进入 `query()`
5. `query()` 调用模型流式 API
6. 模型输出普通文本，直接显示
7. 模型输出 tool use，进入工具执行
8. 工具结果转成 tool result message 再回传模型
9. 如果模型还要继续推理，就继续下一轮
10. 如果结束，就执行 stop hooks、写入 transcript、等待用户下一次输入

### 伪代码

```text
user types prompt

REPL.onSubmit(prompt):
    toolUseContext = buildToolUseContext()
    defaultSystemPrompt = getSystemPrompt()
    userContext = getUserContext()
    systemContext = getSystemContext()
    effectiveSystemPrompt = buildEffectiveSystemPrompt()

    for event in query(
        messages=currentMessages,
        systemPrompt=effectiveSystemPrompt,
        userContext=userContext,
        systemContext=systemContext,
        tools=currentTools,
        canUseTool=permissionChecker,
        toolUseContext=toolUseContext
    ):
        if event is assistant_text:
            render text
        if event is tool_use:
            execute tool
        if event is tool_result:
            append result and continue loop
        if event is final_message:
            persist transcript
            stop
```

---

## 20. 总结

这套项目的实现重点不在某一个单独文件，而在“模块之间如何拼起来”。

从实现思路上看，它有几个鲜明特点：

1. 启动路径做了大量按需加载和并行预热
2. REPL、headless、SDK 共用同一套核心循环
3. 工具、命令、MCP、skills、plugins 都被抽象成统一扩展面
4. 权限、trust、规则文件、会话恢复都是一等公民
5. `query.ts` 才是真正的 agentic runtime 核心

如果继续往下深入，最值得单独精读的文件是：

1. `src/main.tsx`
2. `src/screens/REPL.tsx`
3. `src/query.ts`
4. `src/services/api/claude.ts`
5. `src/tools.ts`
6. `src/utils(1)/claudemd.ts`
7. `src/services/mcp/client.ts`


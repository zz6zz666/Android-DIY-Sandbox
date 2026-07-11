-- Agent 入口 (受保护, 独立于用户 main.lua 加载)
--
-- 本文件由 app 在加载用户 main.lua 之前、单独且受保护地加载。
-- 无论用户把 main.lua 改成什么样、甚至改崩溃, 这里注册的 agent 启动入口
-- (主页顶栏最左侧两个按钮) 都会稳定存在, 不会被用户脚本弄丢。
--
-- 约定: 此处只放最稳定的 agent 入口, 不要堆业务 UI。

local agent = require("agent")

app.agent_actions({
  { icon = "construction", tooltip = "DIY 脚本定制", onTap = function()
    agent.launch("/app-lua-runtime", "opencode-lua")
  end },
  { icon = "smart_toy_outlined", tooltip = "opencode AI 助手", onTap = function()
    agent.launch()
  end },
})

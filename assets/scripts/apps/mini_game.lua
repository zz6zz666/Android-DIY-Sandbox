-- 整屏应用 · 跑酷游戏 (love, 非纯Lua): 独立进程, 独占整个 UI 区域。
-- keepalive=false: 从组件树移除(返回/切到别的 app)即销毁进程, 再进全新启动。
-- (love 的 nav/tab 生命周期由 keepalive/freeze 控制, 不用 lifecycle/unload。)
return {
  title = "跑酷 love(返回即销毁)",
  build = function()
    return love{ id = 1, game = SCRIPTS .. "/games/runner", keepalive = false }
  end,
}

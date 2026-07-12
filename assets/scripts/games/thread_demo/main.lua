-- thread_demo: spawns worker threads that compute and push results via Channel
require("love_host")

local threadOk = false
local counter = 0
local prime = 0         -- latest prime found
local fibN, fibVal = 0, 0
local channel = nil

local function startThreads()
  -- Thread 1: incrementing counter, push every 0.3s
  local t1 = love.thread.newThread([[
    local ch = love.thread.getChannel("td_counter")
    local n = 0
    while true do
      n = n + 1
      ch:push({type="counter", n=n})
    end
  ]])

  -- Thread 2: find next prime, push when found
  local t2 = love.thread.newThread([[
    local ch = love.thread.getChannel("td_prime")
    local function isPrime(n)
      if n < 2 then return false end
      for i = 2, math.sqrt(n) do
        if n % i == 0 then return false end
      end
      return true
    end
    local n = 1
    while true do
      n = n + 1
      if isPrime(n) then
        ch:push({type="prime", n=n})
      end
    end
  ]])

  -- Thread 3: fibonacci
  local t3 = love.thread.newThread([[
    local ch = love.thread.getChannel("td_fibo")
    local a, b, n = 0, 1, 0
    while true do
      a, b = b, a + b
      n = n + 1
      ch:push({type="fibo", n=n, val=a})
    end
  ]])

  t1:start()
  t2:start()
  t3:start()
  print("[thread_demo] 3 worker threads started")
end

function love.load()
  local ok = pcall(function()
    if not love.thread then error("love.thread module not loaded") end
    love.thread.getChannel("td_counter")
    love.thread.getChannel("td_prime")
    love.thread.getChannel("td_fibo")
  end)
  threadOk = ok
  if ok then
    startThreads()
  end
  love.graphics.setBackgroundColor(0.08, 0.09, 0.14)
end

function love.update(dt)
  if not threadOk then return end

  local ch = love.thread.getChannel("td_counter")
  local v = ch:pop()
  while v do
    if v.type == "counter" then counter = v.n end
    v = ch:pop()
  end

  ch = love.thread.getChannel("td_prime")
  v = ch:pop()
  while v do
    if v.type == "prime" then prime = v.n end
    v = ch:pop()
  end

  ch = love.thread.getChannel("td_fibo")
  v = ch:pop()
  while v do
    if v.type == "fibo" then fibN, fibVal = v.n, v.val end
    v = ch:pop()
  end
end

function love.draw()
  local x, y = 20, 40

  love.graphics.setColor(0.5, 0.7, 1.0)
  love.graphics.print("Thread Demo", x, 10)

  if not threadOk then
    love.graphics.setColor(1, 0.4, 0.4)
    love.graphics.print("love.thread NOT available", x, y)
    love.graphics.setColor(1, 1, 1, 0.4)
    love.graphics.print("(native liblove was compiled without thread support)", x, y + 22)
    return
  end

  love.graphics.setColor(0.3, 0.9, 0.4)
  love.graphics.print("3 worker threads running", x, y)

  local lineH = 28
  y = y + lineH + 10

  -- Counter thread
  love.graphics.setColor(0.9, 0.8, 0.3)
  love.graphics.print(string.format("  Counter: %d", counter), x, y)
  y = y + lineH

  -- Prime thread
  love.graphics.setColor(0.3, 0.9, 0.7)
  love.graphics.print(string.format("  Prime:   %d", prime), x, y)
  y = y + lineH

  -- Fibonacci thread
  love.graphics.setColor(0.7, 0.5, 1.0)
  love.graphics.print(string.format("  Fibo #%d: %d", fibN, fibVal), x, y)

  -- instructions
  y = love.graphics.getDimensions()
  love.graphics.setColor(1, 1, 0.5, 0.6)
  love.graphics.print("3 threads: counter, prime finder, fibonacci  |  each runs in its own Lua state", 20, y - 20)
end

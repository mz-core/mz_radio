local function expect(condition, message)
  if not condition then
    error(message, 2)
  end
end

local function resetGlobals()
  Config = nil
  lib = nil
  exports = nil
  source = nil
end

local function loadConfig()
  dofile('config.lua')
end

local function runClientHarness()
  resetGlobals()
  loadConfig()

  local deathState = 'alive'
  local coreStarted = true
  local commands = {}
  local events = {}
  local serverEvents = {}
  local pmaCalls = {}
  local focused = false
  local exported = {}

  exports = setmetatable({
    mz_core = {
      CanLocalPlayerPerformAction = function(_, action)
        expect(action == 'radio.use', 'client used an unexpected canonical action')
        if deathState == nil then error('snapshot unavailable') end
        return deathState == 'alive'
      end
    },
    ['pma-voice'] = {
      setRadioChannel = function(_, channel)
        pmaCalls[#pmaCalls + 1] = { operation = 'channel', value = channel }
      end,
      setVoiceProperty = function(_, property, value)
        pmaCalls[#pmaCalls + 1] = { operation = property, value = value }
      end
    },
    mz_notify = {
      Notify = function() end
    }
  }, {
    __call = function(_, name, callback)
      exported[name] = callback
    end
  })

  function GetCurrentResourceName() return 'mz_radio' end
  function GetResourceState(resource)
    if resource == 'mz_core' then return coreStarted and 'started' or 'stopped' end
    if resource == 'mz_notify' then return 'stopped' end
    return 'started'
  end
  function RegisterCommand(name, callback) commands[name] = callback end
  function RegisterKeyMapping() end
  function RegisterNetEvent(name, callback) events[name] = callback end
  function RegisterNUICallback() end
  function AddEventHandler(name, callback) events[name] = callback end
  function TriggerServerEvent(name, ...)
    serverEvents[#serverEvents + 1] = { name = name, args = { ... } }
  end
  function TriggerEvent() end
  function SendNUIMessage() end
  function SetNuiFocus(value) focused = value == true end

  lib = {
    callback = { await = function() return { ok = true, channels = {} } end },
    notify = function() end
  }

  dofile('client/main.lua')

  commands[Config.OpenCommand](0, {})
  expect(focused, 'alive did not open the radio command')
  commands[Config.OpenCommand](0, {})
  expect(not focused, 'alive did not close the radio command')

  for _, state in ipairs({ 'downed', 'dead', 'respawning' }) do
    deathState = state
    commands[Config.OpenCommand](0, {})
    expect(not focused, state .. ' opened the radio command')

    local countBefore = #serverEvents
    commands[Config.OpenCommand](0, { '1.0' })
    expect(#serverEvents == countBefore, state .. ' bypassed the command with a frequency')
  end

  deathState = nil
  commands[Config.OpenCommand](0, {})
  expect(not focused, 'missing client snapshot did not fail closed')

  coreStarted = false
  deathState = 'alive'
  commands[Config.OpenCommand](0, {})
  expect(not focused, 'stopped mz_core did not fail closed')

  coreStarted = true
  commands[Config.OpenCommand](0, { '1.0' })
  local request = serverEvents[#serverEvents]
  expect(request and request.name == 'mz_radio:server:requestJoin', 'alive frequency command did not request a join')
  events['mz_radio:client:joinResult'](request.args[1], {
    ok = true,
    frequency = 1.0,
    message = 'connected',
    type = 'success'
  })
  expect(pmaCalls[#pmaCalls] and pmaCalls[#pmaCalls].operation == 'channel'
    and pmaCalls[#pmaCalls].value == 1.0, 'alive join did not reach pma-voice')

  deathState = 'downed'
  events['mz_core:client:playerStateSync']({})
  expect(pmaCalls[#pmaCalls - 1] and pmaCalls[#pmaCalls - 1].operation == 'channel'
    and pmaCalls[#pmaCalls - 1].value == 0, 'downed transition did not leave the pma-voice channel')
  expect(pmaCalls[#pmaCalls] and pmaCalls[#pmaCalls].operation == 'radioEnabled'
    and pmaCalls[#pmaCalls].value == false, 'downed transition did not disable radio voice')

  deathState = 'alive'
  commands[Config.OpenCommand](0, {})
  expect(focused, 'radio did not become available after returning alive')

  return true
end

local function runServerHarness()
  resetGlobals()
  loadConfig()

  local states = { [1] = 'alive' }
  local coreStarted = true
  local events = {}
  local handlers = {}
  local callbacks = {}
  local clientEvents = {}
  local channelChecks = {}
  local exported = {}

  exports = setmetatable({
    mz_core = {
      CanPlayerPerformAction = function(_, playerSource, action)
        expect(action == 'radio.use', 'server used an unexpected canonical action')
        local state = states[playerSource]
        if state == nil then return false, { error = 'state_unavailable' } end
        return true, { allowed = state == 'alive' }
      end,
      GetPlayerSnapshot = function() return { citizenid = 'TEST' } end,
      HasPermission = function() return false end
    },
    ['pma-voice'] = {
      addChannelCheck = function(_, frequency, callback)
        channelChecks[frequency] = callback
      end
    }
  }, {
    __call = function(_, name, callback)
      exported[name] = callback
    end
  })

  function GetResourceState(resource)
    if resource == 'mz_core' then return coreStarted and 'started' or 'stopped' end
    return 'started'
  end
  function RegisterNetEvent(name, callback) events[name] = callback end
  function AddEventHandler(name, callback) handlers[name] = callback end
  function TriggerClientEvent(name, target, ...)
    clientEvents[#clientEvents + 1] = { name = name, target = target, args = { ... } }
  end
  function CreateThread(callback) callback() end
  function Wait() end

  MySQL = {
    query = { await = function() return {} end },
    single = { await = function() return nil end },
    insert = { await = function() return 1 end },
    update = { await = function() return 1 end }
  }
  lib = {
    callback = {
      register = function(name, callback) callbacks[name] = callback end
    }
  }

  dofile('server/main.lua')

  local function requestFor(state)
    states[1] = state
    source = 1
    clientEvents = {}
    events['mz_radio:server:requestJoin'](99, 1.0)
    local response = clientEvents[#clientEvents]
    return response and response.args[2]
  end

  local alive = requestFor('alive')
  expect(alive and alive.ok == true, 'server rejected alive radio join')
  expect(exported.GetPlayerRadioChannel(1) == 1.0, 'server did not track alive radio channel')

  for _, state in ipairs({ 'downed', 'dead', 'respawning' }) do
    source = 1
    events['mz_radio:server:leftRadio']()
    local result = requestFor(state)
    expect(result and result.ok == false, 'server allowed radio join while ' .. state)
    expect(exported.GetPlayerRadioChannel(1) == nil, 'server tracked denied channel while ' .. state)
  end

  states[1] = nil
  local unavailable = requestFor(nil)
  expect(unavailable and unavailable.ok == false, 'missing server state did not fail closed')

  coreStarted = false
  states[1] = 'alive'
  local stopped = requestFor('alive')
  expect(stopped and stopped.ok == false, 'stopped mz_core did not fail closed on server')
  coreStarted = true

  states[1] = 'alive'
  expect(channelChecks[1.0] and channelChecks[1.0](1) == true, 'pma-voice check rejected alive')
  states[1] = 'dead'
  expect(channelChecks[1.0](1) == false, 'pma-voice check bypassed dead state')

  requestFor('alive')
  states[1] = 'downed'
  clientEvents = {}
  handlers['mz_core:server:playerDeathStateChangedInternal'](1, {})
  expect(exported.GetPlayerRadioChannel(1) == nil, 'canonical state transition did not clear server channel')
  expect(clientEvents[1] and clientEvents[1].name == 'mz_radio:client:forceLeave'
    and clientEvents[1].target == 1, 'canonical state transition did not force client cleanup')

  states[1] = 'alive'
  local aliveAgain = requestFor('alive')
  expect(aliveAgain and aliveAgain.ok == true, 'server did not allow radio after returning alive')

  return true
end

expect(runClientHarness(), 'client harness did not complete')
expect(runServerHarness(), 'server harness did not complete')

print('[player_state_radio_guard_harness] PASS client/server canonical guard, cleanup, fail-closed')

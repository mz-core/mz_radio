local RESOURCE_NAME = GetCurrentResourceName()

local radioOpen = false
local onRadio = false
local currentChannel = 0.0
local pendingRequests = {}
local requestId = 0
local savedChannels = {}

local function roundFrequency(value)
  local frequency = tonumber(value)
  if not frequency then return nil end

  local decimals = tonumber(Config.DecimalPlaces) or 1
  local factor = 10 ^ decimals

  return math.floor((frequency * factor) + 0.5) / factor
end

local function formatFrequency(frequency)
  frequency = tonumber(frequency) or 0

  if frequency <= 0 then
    return 'OFF'
  end

  local decimals = tonumber(Config.DecimalPlaces) or 1
  return ('%.' .. decimals .. 'f MHz'):format(frequency)
end

local function notify(message, notifyType)
  local payload = {
    type = notifyType or 'info',
    title = Config.NotifyTitle or 'Radio',
    message = message,
    duration = 4500,
    icon = 'radio'
  }

  if GetResourceState('mz_notify') == 'started' then
    exports['mz_notify']:Notify(payload)
    return
  end

  if lib and lib.notify then
    lib.notify({
      type = payload.type,
      title = payload.title,
      description = payload.message,
      duration = payload.duration
    })
    return
  end

  TriggerEvent('chat:addMessage', {
    color = { 90, 190, 255 },
    args = { payload.title, payload.message }
  })
end

local function fetchSavedChannels()
  if Config.SavedChannels and Config.SavedChannels.enabled == false then
    savedChannels = {}
    return savedChannels
  end

  local ok, result = pcall(function()
    return lib.callback.await('mz_radio:server:getSavedChannels', false)
  end)

  if ok and type(result) == 'table' and type(result.channels) == 'table' then
    savedChannels = result.channels
  else
    savedChannels = {}
  end

  return savedChannels
end

local function sendRadioState()
  SendNUIMessage({
    action = 'state',
    connected = onRadio,
    channel = currentChannel,
    channelLabel = formatFrequency(currentChannel),
    savedChannels = savedChannels
  })
end

local function setRadioVisible(visible)
  radioOpen = visible == true
  SetNuiFocus(radioOpen, radioOpen)

  if radioOpen then
    fetchSavedChannels()
  end

  SendNUIMessage({
    action = radioOpen and 'open' or 'close'
  })

  sendRadioState()
end

local function leaveRadio(silent)
  if not onRadio and currentChannel == 0 then
    if not silent then
      notify('Voce nao esta conectado em nenhuma frequencia.', 'warning')
    end
    return
  end

  exports['pma-voice']:setRadioChannel(0)
  exports['pma-voice']:setVoiceProperty('radioEnabled', false)

  onRadio = false
  currentChannel = 0.0

  TriggerServerEvent('mz_radio:server:leftRadio')
  sendRadioState()

  if not silent then
    notify('Radio desligado.', 'error')
  end
end

local function handleJoinResponse(result)
  result = type(result) == 'table' and result or {}

  if not result.ok then
    notify(result.message or 'Nao foi possivel conectar nessa frequencia.', result.type or 'error')
    sendRadioState()
    return
  end

  local frequency = roundFrequency(result.frequency)
  if not frequency then
    notify('Frequencia invalida.', 'error')
    sendRadioState()
    return
  end

  if onRadio then
    exports['pma-voice']:setRadioChannel(0)
  end

  exports['pma-voice']:setVoiceProperty('radioEnabled', true)
  exports['pma-voice']:setRadioChannel(frequency)

  onRadio = true
  currentChannel = frequency
  sendRadioState()

  notify(result.message or ('Conectado em %s.'):format(formatFrequency(frequency)), 'success')
end

local function requestJoin(frequency, nuiCb)
  local normalized = roundFrequency(frequency)

  if not normalized or normalized <= 0 then
    local result = { ok = false, message = 'Informe uma frequencia valida.', type = 'error' }

    if nuiCb then nuiCb(result) end
    notify(result.message, result.type)
    return
  end

  requestId = requestId + 1
  local id = requestId

  pendingRequests[id] = nuiCb or true
  TriggerServerEvent('mz_radio:server:requestJoin', id, normalized)
end

RegisterNetEvent('mz_radio:client:joinResult', function(id, result)
  local pending = pendingRequests[id]
  pendingRequests[id] = nil

  if type(pending) == 'function' then
    pending(result)
  end

  handleJoinResponse(result)
end)

RegisterNetEvent('mz_radio:client:notify', function(message, notifyType)
  notify(message, notifyType)
end)

RegisterNetEvent('mz_radio:client:availableChannels', function(channels)
  channels = type(channels) == 'table' and channels or {}

  if #channels == 0 then
    notify('Nenhum canal disponivel para voce agora.', 'warning')
    return
  end

  notify(('Canais disponiveis: %d. Veja o chat para a lista.'):format(#channels), 'info')

  TriggerEvent('chat:addMessage', {
    color = { 90, 190, 255 },
    args = { 'Radio', 'Canais disponiveis:' }
  })

  for _, channel in ipairs(channels) do
    TriggerEvent('chat:addMessage', {
      color = { 210, 235, 255 },
      args = {
        'Radio',
        ('%s - %s%s'):format(
          formatFrequency(channel.frequency),
          tostring(channel.label or 'Canal'),
          channel.restricted and ' (restrito)' or ''
        )
      }
    })
  end
end)

RegisterCommand(Config.OpenCommand, function(_, args)
  local frequency = args and args[1]

  if frequency and frequency ~= '' then
    requestJoin(frequency)
    return
  end

  setRadioVisible(not radioOpen)
end, false)

RegisterCommand(Config.OffCommand, function()
  leaveRadio(false)
end, false)

RegisterCommand(Config.ListCommand, function()
  TriggerServerEvent('mz_radio:server:listChannels')
end, false)

if Config.OpenKey and Config.OpenKey ~= '' then
  RegisterKeyMapping(Config.OpenCommand, 'Abrir radio', 'keyboard', Config.OpenKey)
end

RegisterNUICallback('join', function(data, cb)
  requestJoin(data and data.frequency, cb)
end)

RegisterNUICallback('leave', function(_, cb)
  leaveRadio(false)
  cb({ ok = true })
end)

RegisterNUICallback('close', function(_, cb)
  setRadioVisible(false)
  cb({ ok = true })
end)

RegisterNUICallback('ready', function(_, cb)
  fetchSavedChannels()
  sendRadioState()
  cb({ ok = true })
end)

RegisterNUICallback('saveChannel', function(data, cb)
  local ok, result = pcall(function()
    return lib.callback.await('mz_radio:server:saveChannel', false, data and data.frequency)
  end)

  if not ok or type(result) ~= 'table' then
    result = { ok = false, message = 'Nao foi possivel salvar o canal.', channels = savedChannels }
  end

  if type(result.channels) == 'table' then
    savedChannels = result.channels
  end

  if result.message and result.message ~= '' then
    notify(result.message, result.ok and 'success' or 'error')
  end

  sendRadioState()
  cb(result)
end)

RegisterNUICallback('removeSavedChannel', function(data, cb)
  local ok, result = pcall(function()
    return lib.callback.await('mz_radio:server:removeSavedChannel', false, data and data.frequency)
  end)

  if not ok or type(result) ~= 'table' then
    result = { ok = false, message = 'Nao foi possivel remover o canal.', channels = savedChannels }
  end

  if type(result.channels) == 'table' then
    savedChannels = result.channels
  end

  if result.message and result.message ~= '' then
    notify(result.message, result.ok and 'success' or 'error')
  end

  sendRadioState()
  cb(result)
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= RESOURCE_NAME then return end

  if onRadio then
    exports['pma-voice']:setRadioChannel(0)
    exports['pma-voice']:setVoiceProperty('radioEnabled', false)
  end

  SetNuiFocus(false, false)
end)

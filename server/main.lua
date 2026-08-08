local activeChannels = {}
local registeredChecks = {}
local radioStorageReady = false

local function roundFrequency(value)
  local frequency = tonumber(value)
  if not frequency then return nil end

  local decimals = tonumber(Config.DecimalPlaces) or 1
  local factor = 10 ^ decimals

  return math.floor((frequency * factor) + 0.5) / factor
end

local function formatFrequency(frequency)
  local decimals = tonumber(Config.DecimalPlaces) or 1
  return ('%.' .. decimals .. 'f MHz'):format(tonumber(frequency) or 0)
end

local function getPlayerCitizenId(source)
  if GetResourceState('mz_core') ~= 'started' then
    return nil
  end

  local player = exports['mz_core']:GetPlayerSnapshot(source)
  return player and player.citizenid or nil
end

local function prepareRadioStorage()
  local ok, err = pcall(function()
    MySQL.query.await([[
      CREATE TABLE IF NOT EXISTS mz_radio_saved_channels (
        id INT AUTO_INCREMENT PRIMARY KEY,
        citizenid VARCHAR(32) NOT NULL,
        frequency DECIMAL(10,2) NOT NULL,
        label VARCHAR(64) NOT NULL DEFAULT '',
        sort_order INT NOT NULL DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        UNIQUE KEY uq_mz_radio_saved_channel (citizenid, frequency),
        KEY idx_mz_radio_saved_citizenid (citizenid)
      )
    ]])
  end)

  radioStorageReady = ok == true

  if not ok then
    print(('[mz_radio] falha ao preparar tabela de canais salvos: %s'):format(err))
    return
  end

  print('[mz_radio] tabela de canais salvos pronta')
end

local function normalizeSavedChannelRow(row)
  local frequency = roundFrequency(row and row.frequency)
  if not frequency then return nil end

  return {
    frequency = frequency,
    label = tostring(row.label or formatFrequency(frequency))
  }
end

local function getSavedChannels(source)
  if Config.SavedChannels and Config.SavedChannels.enabled == false then
    return {}
  end

  if not radioStorageReady then
    return {}
  end

  local citizenid = getPlayerCitizenId(source)
  if not citizenid then
    return {}
  end

  local rows = MySQL.query.await([[
    SELECT frequency, label
    FROM mz_radio_saved_channels
    WHERE citizenid = ?
    ORDER BY sort_order DESC, updated_at DESC, id DESC
  ]], { citizenid }) or {}

  local channels = {}

  for _, row in ipairs(rows) do
    local channel = normalizeSavedChannelRow(row)
    if channel then
      channels[#channels + 1] = channel
    end
  end

  return channels
end

local function saveChannel(source, frequency)
  if Config.SavedChannels and Config.SavedChannels.enabled == false then
    return false, 'Salvamento de canais desativado.'
  end

  if not radioStorageReady then
    return false, 'Banco do radio ainda nao esta pronto.'
  end

  local citizenid = getPlayerCitizenId(source)
  if not citizenid then
    return false, 'Personagem nao carregado.'
  end

  local normalized = roundFrequency(frequency)
  if not normalized or normalized <= 0 then
    return false, 'Frequencia invalida.'
  end

  if normalized > (tonumber(Config.MaxFrequency) or 500.0) then
    return false, 'Frequencia fora do limite permitido.'
  end

  local maxSaved = tonumber(Config.SavedChannels and Config.SavedChannels.max) or 12
  local countRow = MySQL.single.await([[
    SELECT COUNT(1) AS total
    FROM mz_radio_saved_channels
    WHERE citizenid = ?
  ]], { citizenid })
  local total = tonumber(countRow and countRow.total) or 0

  local existing = MySQL.single.await([[
    SELECT id
    FROM mz_radio_saved_channels
    WHERE citizenid = ? AND frequency = ?
    LIMIT 1
  ]], { citizenid, normalized })

  if not existing and total >= maxSaved then
    return false, ('Limite de %d canais salvos atingido.'):format(maxSaved)
  end

  local nowOrder = os.time()

  MySQL.insert.await([[
    INSERT INTO mz_radio_saved_channels (citizenid, frequency, label, sort_order)
    VALUES (?, ?, ?, ?)
    ON DUPLICATE KEY UPDATE
      label = VALUES(label),
      sort_order = VALUES(sort_order),
      updated_at = CURRENT_TIMESTAMP
  ]], {
    citizenid,
    normalized,
    formatFrequency(normalized),
    nowOrder
  })

  return true, 'Canal salvo.', getSavedChannels(source)
end

local function removeSavedChannel(source, frequency)
  if not radioStorageReady then
    return false, 'Banco do radio ainda nao esta pronto.'
  end

  local citizenid = getPlayerCitizenId(source)
  if not citizenid then
    return false, 'Personagem nao carregado.'
  end

  local normalized = roundFrequency(frequency)
  if not normalized then
    return false, 'Frequencia invalida.'
  end

  MySQL.update.await([[
    DELETE FROM mz_radio_saved_channels
    WHERE citizenid = ? AND frequency = ?
  ]], { citizenid, normalized })

  return true, 'Canal removido.', getSavedChannels(source)
end

local function getConfiguredChannel(frequency)
  local normalized = roundFrequency(frequency)
  if not normalized then return nil end

  for configFrequency, channelConfig in pairs(Config.Channels or {}) do
    if roundFrequency(configFrequency) == normalized then
      return channelConfig
    end
  end

  return nil
end

local function notify(source, message, notifyType)
  TriggerClientEvent('mz_radio:client:notify', source, message, notifyType or 'info')
end

local function hasRadioPermission(source, channelConfig)
  if not channelConfig or channelConfig.restricted ~= true then
    return true
  end

  local permissions = channelConfig.permissions or {}
  if #permissions == 0 then
    return false
  end

  if GetResourceState('mz_core') ~= 'started' then
    -- TODO: adaptar aqui se a API de permissoes do mz_core mudar ou se outro core for usado.
    return false
  end

  for _, permission in ipairs(permissions) do
    if exports['mz_core']:HasPermission(source, permission) then
      return true
    end
  end

  return false
end

local function validateFrequency(source, frequency)
  local normalized = roundFrequency(frequency)

  if not normalized or normalized <= 0 then
    return false, 'Frequencia invalida.', nil, 'error'
  end

  if normalized > (tonumber(Config.MaxFrequency) or 500.0) then
    return false, 'Frequencia fora do limite permitido.', nil, 'error'
  end

  local channelConfig = getConfiguredChannel(normalized)

  if channelConfig and channelConfig.restricted == true and not hasRadioPermission(source, channelConfig) then
    return false, 'Voce nao tem permissao para essa frequencia.', normalized, 'error'
  end

  return true, nil, normalized, 'success'
end

local function buildAvailableChannels(source)
  local channels = {}

  for frequency, channelConfig in pairs(Config.Channels or {}) do
    local normalized = roundFrequency(frequency)

    if normalized and hasRadioPermission(source, channelConfig) then
      channels[#channels + 1] = {
        frequency = normalized,
        label = tostring(channelConfig.label or 'Canal'),
        restricted = channelConfig.restricted == true
      }
    end
  end

  table.sort(channels, function(a, b)
    return (tonumber(a.frequency) or 0) < (tonumber(b.frequency) or 0)
  end)

  return channels
end

RegisterNetEvent('mz_radio:server:requestJoin', function(requestId, frequency)
  local src = source
  local ok, message, normalized, notifyType = validateFrequency(src, frequency)

  if ok then
    activeChannels[src] = normalized
    message = ('Conectado em %s.'):format(formatFrequency(normalized))
  end

  TriggerClientEvent('mz_radio:client:joinResult', src, requestId, {
    ok = ok,
    frequency = normalized,
    message = message,
    type = notifyType
  })
end)

RegisterNetEvent('mz_radio:server:leftRadio', function()
  activeChannels[source] = nil
end)

RegisterNetEvent('mz_radio:server:listChannels', function()
  local src = source
  TriggerClientEvent('mz_radio:client:availableChannels', src, buildAvailableChannels(src))
end)

lib.callback.register('mz_radio:server:getSavedChannels', function(source)
  return {
    ok = true,
    channels = getSavedChannels(source)
  }
end)

lib.callback.register('mz_radio:server:saveChannel', function(source, frequency)
  local ok, message, channels = saveChannel(source, frequency)

  return {
    ok = ok,
    message = message,
    channels = channels or getSavedChannels(source)
  }
end)

lib.callback.register('mz_radio:server:removeSavedChannel', function(source, frequency)
  local ok, message, channels = removeSavedChannel(source, frequency)

  return {
    ok = ok,
    message = message,
    channels = channels or getSavedChannels(source)
  }
end)

AddEventHandler('playerDropped', function()
  activeChannels[source] = nil
end)

local function registerPmaChannelChecks()
  if GetResourceState('pma-voice') ~= 'started' then
    print('[mz_radio] aviso: pma-voice nao esta iniciado; checks de canal serao registrados quando ele iniciar.')
    return
  end

  for frequency, channelConfig in pairs(Config.Channels or {}) do
    local normalized = roundFrequency(frequency)

    if normalized and not registeredChecks[normalized] then
      registeredChecks[normalized] = true

      exports['pma-voice']:addChannelCheck(normalized, function(source)
        local ok = validateFrequency(source, normalized)
        return ok == true
      end)

      if channelConfig.restricted == true then
        print(('[mz_radio] canal restrito registrado no pma-voice: %s'):format(formatFrequency(normalized)))
      end
    end
  end
end

CreateThread(function()
  Wait(500)
  prepareRadioStorage()
  registerPmaChannelChecks()
end)

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= 'pma-voice' then return end

  registeredChecks = {}
  Wait(500)
  registerPmaChannelChecks()
end)

exports('HasRadioPermission', hasRadioPermission)
exports('GetPlayerRadioChannel', function(source)
  return activeChannels[source]
end)

Config = {}

Config.OpenCommand = 'radio'
Config.OffCommand = 'radiooff'
Config.ListCommand = 'radios'
Config.OpenKey = ''

Config.MaxFrequency = 500.0
Config.DecimalPlaces = 1
Config.NotifyTitle = 'Radio'

Config.MultiRadio = {
  enabled = false,
  maxActiveChannels = 1
}

Config.SavedChannels = {
  enabled = true,
  max = 12
}

Config.Channels = {
  [1.0] = {
    label = 'Publica',
    restricted = false
  },
  [190.1] = {
    label = 'PMERJ',
    restricted = true,
    permissions = { 'perm.pmerj', 'perm.admin' }
  },
  [191.1] = {
    label = 'PRF',
    restricted = true,
    permissions = { 'perm.prf', 'perm.admin' }
  },
  [192.1] = {
    label = 'Hospital',
    restricted = true,
    permissions = { 'perm.hospital', 'perm.admin' }
  }
}

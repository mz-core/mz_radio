fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_radio'
author 'Mazus'
description 'Radio NUI para mz_core + pma-voice'
version '0.1.0'

ui_page 'web/index.html'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua'
}

client_scripts {
  'client/main.lua'
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua'
}

files {
  'web/index.html',
  'web/style.css',
  'web/app.js',
  'web/assets/**'
}

dependencies {
  'ox_lib',
  'oxmysql',
  'mz_core',
  'pma-voice'
}

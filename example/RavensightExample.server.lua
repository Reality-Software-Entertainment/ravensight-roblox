-- A server Script. Game Settings > Security > Allow HTTP Requests must be on,
-- and Studio Access to API Services for DataStores while testing in Studio.
local ServerScriptService = game:GetService('ServerScriptService')
local ServerStorage = game:GetService('ServerStorage')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Players = game:GetService('Players')

local Ravensight = require(ServerScriptService.Ravensight)
local secrets = require(ServerStorage.RavensightSecrets)

Ravensight.init({
  ingestKey = secrets.ingestKey,
  salt = secrets.salt,
  debug = game:GetService('RunService'):IsStudio(),
})

-- The player's own choice, from a button on their screen. Roblox tells the
-- server which player fired the event, so a client cannot opt out another.
ReplicatedStorage.RavensightOptOut.OnServerEvent:Connect(function(player, enabled)
  Ravensight.setTrackingEnabled(player, enabled == true)
end)

-- Gameplay events, always for one player.
Players.PlayerAdded:Connect(function(player)
  player.CharacterAdded:Connect(function(character)
    Ravensight.track(player, 'spawned', { rs_kind = 'level_start', level = 'lobby' })
    local humanoid = character:WaitForChild('Humanoid')
    humanoid.Died:Connect(function()
      Ravensight.track(player, 'died', { rs_kind = 'death', level = 'lobby' })
    end)
  end)
end)

-- Remote config: reading a value marks the player as seen by any running
-- experiment, so read it where the value is used.
Players.PlayerAdded:Connect(function(player)
  Ravensight.fetchConfig(player)
  task.wait(5)
  local walkSpeed = Ravensight.getConfig(player, 'walk_speed', 16)
  print(player.Name, 'walk speed', walkSpeed)
end)

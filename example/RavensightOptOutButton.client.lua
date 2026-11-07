-- A LocalScript: a small analytics switch on the player's screen.
local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local gui = Instance.new('ScreenGui')
gui.ResetOnSpawn = false
local button = Instance.new('TextButton')
button.Size = UDim2.fromOffset(180, 36)
button.Position = UDim2.new(1, -190, 1, -46)
button.Text = 'Analytics: on'
button.Parent = gui
gui.Parent = Players.LocalPlayer:WaitForChild('PlayerGui')

local enabled = true
button.Activated:Connect(function()
  enabled = not enabled
  button.Text = enabled and 'Analytics: on' or 'Analytics: off'
  ReplicatedStorage.RavensightOptOut:FireServer(enabled)
end)

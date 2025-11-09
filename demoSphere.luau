local ECS = require(game.ReplicatedStorage.ECS)
local RunService = game:GetService("RunService")

local world = ECS.World.new()

local MovementSystem = ECS.Systems().Movement()
world:registerSystem(MovementSystem)

local RenderSystem = {
	name = "SphereSurfaceFlow",
	priority = 50,
}

function RenderSystem:update(world, dt)
	local center = world:query({ all = {"SphereCenter"} })[1]
	if not center then return end
	local centerPos = world:getComponent(center, "Position")

	local parts = world:query({ all = {"LocalOffset", "SurfaceDirection", "Model"} })

	local speed = 5

	for _, id in ipairs(parts) do
		local offset = world:getComponent(id, "LocalOffset")
		local dir = world:getComponent(id, "SurfaceDirection")
		local inst = world:getComponent(id, "Model")

		local radius = offset.Magnitude
		local normal = offset.Unit

		dir = (dir - (dir:Dot(normal)) * normal).Unit

		local newOffset = offset + dir * dt * speed
		newOffset = newOffset.Unit * radius

		world:replaceComponent(id, "LocalOffset", newOffset)
		world:replaceComponent(id, "SurfaceDirection", dir)

		if inst:IsA("BasePart") then
			inst.CFrame = CFrame.new(centerPos + newOffset)
		end
	end
end

world:registerSystem(RenderSystem)


local center = world:createEntity({
	Position = Vector3.new(0, 15, 0),
	SphereCenter = true,
})


local function randomPointOnSphere(radius)
	local u = math.random()
	local v = math.random()
	local theta = math.acos(2*u - 1)
	local phi = 2 * math.pi * v
	local x = radius * math.sin(theta) * math.cos(phi)
	local y = radius * math.sin(theta) * math.sin(phi)
	local z = radius * math.cos(theta)
	return Vector3.new(x, y, z)
end

local radius = 15
local count = 350
local function randomUnitVector()
	return Vector3.new(
		math.random() - 0.5,
		math.random() - 0.5,
		math.random() - 0.5
	).Unit
end

for i = 1, count do
	local part = Instance.new("Part")
	part.Size = Vector3.new(1, 1, 1)
	part.Anchored = true
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(0, 170, 255)
	part.Parent = workspace

	local offset = randomPointOnSphere(radius)
	local normal = offset.Unit

	local tangent = (randomUnitVector() - (randomUnitVector():Dot(normal)) * normal).Unit

	world:createEntity({
		Model = part,
		LocalOffset = offset,
		SurfaceDirection = tangent,
	}, {"SpherePart"})
end

RunService.Heartbeat:Connect(function(dt)
	world:update(dt)
end)

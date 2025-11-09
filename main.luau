-- main ecs table
local ECS_System = {}
ECS_System.__index = ECS_System

-- just copies a table (not deep)
local function createShallowCopy(copiedTable)
	local output = {}
	for key, value in pairs(copiedTable) do
		output[key] = value
	end
	return output
end

-- removes one item from an array style table
local function table_removeValue(tab, value)
	for i = 1, #tab do
		if tab[i] == value then
			table.remove(tab, i)
			return true
		end
	end
	return false
end

-- tiny signal system cuz roblox events kinda annoying sometimes
local function Signal()
	local listeners = {} ; local signal = {}

	function signal:connect(func)
		if type(func) ~= "function" then error("need function bro") end
		table.insert(listeners, func)
		local connection = {}
		function connection:Disconnect()
			table_removeValue(listeners, func)
		end
		return connection
	end

	function signal:fire(...)
		for i = 1, #listeners do
			local ok, err = pcall(listeners[i], ...)
			if not ok then warn("signal callback cooked itself:", err) end
		end
	end

	function signal:clear()
		for i = #listeners, 1, -1 do listeners[i] = nil end
	end

	return signal
end

-- entity id factory so ids dont get stupid high
local idPool = {}
do
	local nextId = 0
	local recycled = {}

	function idPool:next()
		if #recycled > 0 then
			return table.remove(recycled)
		end
		nextId += 1
		return nextId
	end

	function idPool:release(id)
		table.insert(recycled, id)
	end
end

-- world = main ecs manager
local World = {}
World.__index = World

function World.new(options)
	options = options or {}
	local self = setmetatable({
		_entities = {},              -- all entity ids we got rn
		_entityComponents = {},      -- what components each entity has
		_components = {},            -- the actual component data
		_systems = {},               -- systems we run every update
		_deferred = {                -- stuff we queue so we dont break loops
			add = {},
			remove = {},
			addComp = {},
			removeComp = {},
		},
		_isRunning = false,          -- true while systems are running
		_queryCache = {},            -- caching cuz searching every frame is pain
		_tags = {},                  -- tag lookup basically
		_signals = {
			entityAdded = Signal(),
			entityRemoved = Signal(),
		},
		_profiler = options.profiler or nil, -- ignore if u dont need it
	}, World)
	return self
end

-- makes sure the component bucket exists
local function ensureComponentsTable(self, componentName)
	if not self._components[componentName] then
		self._components[componentName] = {}
	end
end

-- checks if entity matches a query (what components/tags it needs)
local function matchEntitySignature(self, entityId, signature)
	local entityComponent = self._entityComponents[entityId] or {}

	if signature.all then
		for _, component in ipairs(signature.all) do
			if not entityComponent[component] then return false end
		end
	end

	if signature.any then
		local found = false
		for _, component in ipairs(signature.any) do
			if entityComponent[component] then
				found = true break
			end
		end
		if not found then return false end
	end

	if signature.none then
		for _, component in ipairs(signature.none) do
			if entityComponent[component] then return false end
		end
	end

	if signature.tags then
		for _, tag in ipairs(signature.tags) do
			local tagSet = self._tags[tag]
			if not tagSet or not tagSet[entityId] then return false end
		end
	end

	return true
end

-- update cached queries (so queries stay fast)
local function updateQueryCache_EntityChange(self, entityId)
	for _, value in pairs(self._queryCache) do
		local matches = matchEntitySignature(self, entityId, value.signature)
		local existed = value.entitiesSet[entityId] ~= nil
		if matches and not existed then
			value.entitiesSet[entityId] = true
			table.insert(value.entitiesList, entityId)
		elseif not matches and existed then
			value.entitiesSet[entityId] = nil
			table_removeValue(value.entitiesList, entityId)
		end
	end
end

-- makes an entity (basically just giving it an id and components)
function World:createEntity(initComponents, tags)
	initComponents = initComponents or {}
	tags = tags or {}

	local id = idPool:next()
	self._entities[id] = true
	self._entityComponents[id] = {}

	for name, data in pairs(initComponents) do
		ensureComponentsTable(self, name)
		self._components[name][id] = data
		self._entityComponents[id][name] = true
	end

	for _, tag in ipairs(tags) do
		self._tags[tag] = self._tags[tag] or {}
		self._tags[tag][id] = true
	end

	updateQueryCache_EntityChange(self, id)
	self._signals.entityAdded:fire(id)
	return id
end

-- deletes entity & wipes components
function World:destroyEntity(id)
	if not self._entities[id] then return end

	if self._isRunning then
		self._deferred.remove[id] = true return
	end

	local comps = self._entityComponents[id] or {}
	for name in pairs(comps) do
		self._components[name][id] = nil
	end

	self._entityComponents[id] = nil

	for _, tagSet in pairs(self._tags) do
		tagSet[id] = nil
	end

	self._entities[id] = nil
	idPool:release(id)
	updateQueryCache_EntityChange(self, id)
	self._signals.entityRemoved:fire(id)
end

-- just checks it exists
function World:hasEntity(id)
	return self._entities[id] ~= nil
end

-- add component to entity
function World:addComponent(entityId, name, data)
	if not self._entities[entityId] then error("entity does not exist") end

	if self._isRunning then
		-- queue it so we dont mess up system loops
		self._deferred.addComp[#self._deferred.addComp + 1] = { entity = entityId, name = name, data = data }
		return
	end

	ensureComponentsTable(self, name)
	self._components[name][entityId] = data
	self._entityComponents[entityId][name] = true
	updateQueryCache_EntityChange(self, entityId)
end

-- remove component
function World:removeComponent(entityId, name)
	if not self._entities[entityId] then error("entity does not exist") end

	if self._isRunning then
		self._deferred.removeComp[#self._deferred.removeComp + 1] = { entity = entityId, name = name }
		return
	end

	if self._components[name] then
		self._components[name][entityId] = nil
	end
	if self._entityComponents[entityId] then
		self._entityComponents[entityId][name] = nil
	end

	updateQueryCache_EntityChange(self, entityId)
end

-- grab component
function World:getComponent(entityId, name)
	if not self._entities[entityId] then return nil end
	if not self._components[name] then return nil end
	return self._components[name][entityId]
end

-- replace component (immutable style)
function World:replaceComponent(entityId, name, data)
	ensureComponentsTable(self, name)
	self._components[name][entityId] = data
	self._entityComponents[entityId][name] = true
	updateQueryCache_EntityChange(self, entityId)
end

-- querying system basically finds entities with matching components
function World:query(signature)
	signature = signature or {}
	local key = ""
	if signature.all then key ..= "a" end
	if signature.any then key ..= "b" end
	if signature.none then key ..= "c" end
	if signature.tags then key ..= "d" end

	local cached = self._queryCache[key]
	if cached then return cached.entitiesList end

	local result = {}
	local set = {}
	for id in pairs(self._entities) do
		if matchEntitySignature(self, id, signature) then
			set[id] = true
			table.insert(result, id)
		end
	end

	self._queryCache[key] = { signature = createShallowCopy(signature), entitiesList = result, entitiesSet = set }
	return result
end

-- register a system (runs every update)
function World:registerSystem(system)
	system.priority = system.priority or 0
	system.name = system.name or "system"
	table.insert(self._systems, system)
	table.sort(self._systems, function(a,b) return a.priority > b.priority end)
end

-- runs systems, then applies queued changes
function World:update(deltaTime)
	self._isRunning = true
	for _, system in ipairs(self._systems) do
		local ok, err = pcall(system.update, system, self, deltaTime)
		if not ok then warn("system error:", err) end
	end
	self._isRunning = false

	-- apply queued component/entity changes now
	self:_applyDeferred()
end

ECS_System.World = World

-- basic system example: movement
function ECS_System.Systems()
	local Systems = {}

	function Systems.Movement()
		local system = {}
		system.name = "MovementSystem"
		system.priority = 100

		function system:update(world, deltaTime)
			-- find things that have both pos + vel
			local list = world:query({ all = {"Position", "Velocity"} })
			for _, id in ipairs(list) do
				local pos = world:getComponent(id, "Position")
				local vel = world:getComponent(id, "Velocity")
				world:replaceComponent(id, "Position", pos + vel * deltaTime)
			end
		end

		return system
	end

	return Systems
end

return ECS_System

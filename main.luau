local ECS_System = {}
ECS_System.__index = ECS_System

local function createShallowCopy(copiedTable): {[any]: any}
	local output = {}
	for key, value in pairs(copiedTable) do
		output[key] = value
	end
	return output
end

local function table_removeValue(tab, value)
	for i = 1, #tab do
		if tab[i] == value then
			table.remove(tab, i)
			return true
		end
	end
	return false
end

local function Signal()
	local listeners = {} ; local signal = {}

	function signal:connect(func)
		if type(func) ~= "function" then error('ECS :: createSignal :: Signal:connect requires function argument') end
		table.insert(listeners, func)
		local connection = {}
		function connection:Disconnect()
			table_removeValue(listeners, func)
		end
		return connection
	end

	function signal:fire(...)
		for i = 1, #listeners do
			local success, errorMessage = pcall(listeners[i], ...)
			if not success then
				warn(`ECS :: Signal :: Signal listener error: {errorMessage}`)
			end
		end
	end

	function signal:clear()
		for i = #listeners, 1, -1 do
			listeners[i] = nil
		end
	end

	return signal
end

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

local World = {}
World.__index = World

function World.new(options)
	options = options or {}
	local self = setmetatable({
		_entities = {},
		_entityComponents = {},
		_components = {},
		_systems = {},
		_deferred = {
			add = {},
			remove = {},
			addComp = {},
			removeComp = {},
		},
		_isRunning = false,
		_queryCache = {},
		_tags = {},
		_signals = {
			entityAdded = Signal(),
			entityRemoved = Signal(),
		},
		_profiler = options.profiler or nil,
	}, World)
	return self
end

local function ensureComponentsTable(self, componentName: string): ()
	if not self._components[componentName] then
		self._components[componentName] = {}
	end
end

local function matchEntitySignature(self, entityId, signature): boolean
	local entityComponent = self._entityComponents[entityId] or {}

	if signature.all then
		for _, component in ipairs(signature.all) do
			if not entityComponent[component] then
				return false
			end
		end
	end

	if signature.any then
		local found = false
		for _, component in ipairs(signature.any) do
			if entityComponent[component] then
				found = true ; break
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
			if not tagSet or not tagSet[entityId] then
				return false
			end
		end
	end

	return true
end

local function updateQueryCache_EntityChange(self, entityId): ()
	for key, value in pairs(self._queryCache) do
		local matches = matchEntitySignature(self, entityId, value.signature)
		local existed = value.entitiesSet[entityId] ~= nil
		if matches and not existed then
			value.entitiesSet[entityId] = true
			table.insert(value.entitiesSet, entityId)
		elseif not matches and existed then
			value.entitiesSet[entityId] = nil
			table_removeValue(value.entitiesList, entityId)
		end
	end
end

function World:createEntity(initComponents, tags)
	initComponents = initComponents or {}
	tags = tags or {}

	local id = idPool:next()
	self._entities[id] = true
	self._entityComponents[id] = {}

	for componentName, componentData in pairs(initComponents) do
		ensureComponentsTable(self, componentName)
		self._components[componentName][id] = componentData
		self._entityComponents[id][componentName] = true
	end

	for _, tag in ipairs(tags) do
		self._tags[tag] = self._tags[tag] or {}
		self._tags[tag][id] = true
	end

	updateQueryCache_EntityChange(self, id)
	self._signals.entityAdded:fire(id)

	return id
end

function World:destroyEntity(id): ()
	if not self._entities[id] then return end

	if self._isRunning then
		self._deferred.remove[id] = true ; return
	end

	local components = self._entityComponents[id] or {}
	for componentName, _ in pairs(components) do
		self._components[componentName][id] = nil
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

function World:hasEntity(id): boolean
	return self._entities[id] ~= nil
end

function World:addComponent(entityId, componentName, componentData)
	if not self._entities[entityId] then
		error('ECS :: World:addComponent :: Entity does not exist.')
	end

	if self._isRunning then
		self._deferred.addComp[#self._deferred.addComp + 1] = {
			entity = entityId,
			name = componentName,
			data = componentData,
		}
		return
	end

	ensureComponentsTable(self, componentName)
	self._components[componentName][entityId] = componentData
	self._entityComponents[entityId][componentName] = true
	updateQueryCache_EntityChange(self, entityId)
end

function World:removeComponent(entityId, componentName)
	if not self._entities[entityId] then
		error('ECS :: World:removeComponent :: Entity does not exist.')
	end

	if self._isRunning then
		self._deferred.removeComp[#self._deferred.removeComp + 1] = {
			entity = entityId,
			name = componentName,
		}
		return
	end

	if self._components[componentName] then
		self._components[componentName][entityId] = nil
	end
	if self._entityComponents[entityId] then
		self._entityComponents[entityId][componentName] = nil
	end

	updateQueryCache_EntityChange(self, entityId)
end

function World:getComponent(entityId, componentName)
	if not self._entities[entityId] then return nil end
	if not self._components[componentName] then return nil end
	return self._components[componentName][entityId]
end

function World:replaceComponent(entityId, componentName, componentData): ()
	if not self._entities[entityId] then
		error('ECS :: World:replaceComponent :: Entity does not exist.')
	end

	ensureComponentsTable(self, componentName)
	self._components[componentName][entityId] = componentData
	self._entityComponents[entityId][componentName] = true
	updateQueryCache_EntityChange(self, entityId)
end

function World:addTag(entityId, tag): ()
	self._tags[tag] = self._tags[tag] or {}
	self._Tags[tag][entityId] = true
	updateQueryCache_EntityChange(self, entityId)
end

function World:removeTag(entityId, tag): ()
	if self._tags[tag] then
		self._tags[tag][entityId] = nil
	end
	updateQueryCache_EntityChange(self, entityId)
end

local function signatureToKey(signature): string
	local parts = {}
	if signature.all then
		table.sort(signature.all)
		table.insert(parts, `A: {table.concat(signature.all, ',')}`)
	end
	if signature.any then
		table.sort(signature.any)
		table.insert(parts, `Y: {table.concat(signature.any, ',')}`)
	end
	if signature.none then
		table.sort(signature.none)
		table.insert(parts, `N: {table.concat(signature.none, ',')}`)
	end
	if signature.tags then
		table.sort(signature.tags)
		table.insert(parts, `T: {table.concat(signature.tags, ',')}`)
	end

	return table.concat(parts, '|')
end

function World:query(signature)
	signature = signature or {}

	local key = signatureToKey(signature)
	local cached = self._queryCache[key]
	if cached then return cached.entitiesList end

	local resultList = {}
	local resultSet = {}
	for id, _ in pairs(self._entities) do
		if matchEntitySignature(self, id, signature) then
			resultSet[id] = true
			table.insert(resultList, id)
		end
	end

	self._queryCache[key] = {
		signature = createShallowCopy(signature),
		entitiesList = resultList,
		entitiesSet = resultSet
	}
	return resultList
end

function World:registerSystem(system)
	system.priority = system.priority or 0
	system.name = system.name or (`sys_{tostring(system)}`)
	table.insert(self._systems, system)
	table.sort(self._systems, function(a, b)
		return a.priority > b.priority
	end)
end

function World:unregisterSystem(systemName)
	for i = #self._systems, 1, -1 do
		if self._systems[i].name == systemName then
			table.remove(self._systems, i) ; break
		end
	end
end

function World:_applyDeferred()
	for id, _ in pairs(self._deferred.remove) do
		if self._entities[id] then
			local components = self._entityComponents[id] or {}
			for componentName, _ in pairs(components) do
				if self._components[componentName] then
					self._components[componentName][id] = nil
				end
			end
			self._entityComponents[id] = nil
			for tagName, tagSet in pairs(self._tags) do
				tagSet[id] = nil
			end
			self._entities[id] = nil
			idPool:release(id)
			updateQueryCache_EntityChange(self, id)
			self._signals.entityRemoved:fire()
		end
	end

	self._deferred.remove = {}

	for _, entry in ipairs(self._deferred.addComp) do
		ensureComponentsTable(self, entry.name)
		self._components[entry.name][entry.entity] = entry.data
		self._entityComponents[entry.entity][entry.name] = true
		updateQueryCache_EntityChange(self, entry.entity)
	end

	self._deferred.addComp = {}

	for _, entry in ipairs(self._deferred.removeComp) do
		if self._components[entry.name] then
			self._components[entry.name][entry.entity] = nil
		end
		if self._entityComponents[entry.entity] then
			self._entityComponents[entry.entity][entry.name] = nil
		end
		updateQueryCache_EntityChange(self, entry.entity)
	end

	self._deferred.removeComp = {}
end

function World:update(deltaTime)
	self._isRunning = true
	for _, system in ipairs(self._systems) do
		local function runSystem()
			local success, errorMessage = pcall(system.update, system, self, deltaTime)
			if not success then
				warn(("System '%s' error: %s"):format(system.name or "?", tostring(errorMessage)))
			end
		end
		if self._profiler then
			self._profiler(system.name or 'system', function() runSystem() end)
		else
			runSystem()
		end
	end
	self._isRunning = false
	self:_applyDeferred()
end

function World:serializeEntity(entityId)
	if not self._entities[entityId] then return nil end
	local output = { id = entityId, components = {}, tags = {} }
	local components = self._entityComponents[entityId] or {}
	for componentName, _ in pairs(components) do
		output.components[componentName] = self._components[componentName][entityId]
	end
	for tagName, tagSet in pairs(self._tags) do
		if tagSet[entityId] then table.insert(output.tags, tagName) end
	end
	return output
end

function World:serialize()
	local data = { entities = {} }
	for id, _ in pairs(self._entities) do
		table.insert(data.entities, self:serializeEntity(id))
	end
	return data
end

function World:deserialize(data, options)
	options = options or {}
	if options.clear then
		for id, _ in pairs(self._entities) do
			self:destroyEntity(id)
		end
	end
	for _, e in ipairs(data.entities or {}) do
		local id = self:createEntity(e.components, e.tags)
	end
end

function World:stats()
	local componentCounts = {}
	local totalEntities = 0
	for id, _ in pairs(self._entities) do
		totalEntities += 1
	end
	for componentName, map in pairs(self._components) do
		componentCounts[componentName] = 0
		for _ in pairs(map) do
			componentCounts[componentName] = componentCounts[componentName] + 1
		end
	end
	return {
		entityCount = totalEntities,
		componentCounts = componentCounts,
		systemCount = #self._systems
	}
end

function World:clear()
	for id, _ in pairs(self._entities) do
		self:destroyEntity(id)
	end
	self._components = {}
	self._entityComponents = {}
	self._queryCache = {}
	self._tags = {}
end

function World:onEntityAdded(func)
	return self._signals.entityAdded:connect(func)
end

function World:onEntityRemoved(func)
	return self._signals.entityRemoved:connect(func)
end

ECS_System.World = World

function ECS_System.Systems()
	local Systems = {}

	function Systems.Movement()
		local system = {}
		system.name = "MovementSystem"
		system.priority = 100

		function system:update(world, deltaTime)
			local list = world:query({ all = {'Position', 'Velocity'} })
			for i = 1, #list do
				local id = list[i]
				local position = world:getComponent(id, 'Position')
				local velocity = world:getComponent(id, 'Velocity')

				if typeof(position) == "Vector3" and typeof(velocity) == "Vector3" then
					world:replaceComponent(id, 'Position', position + velocity * deltaTime)
				elseif type(position) == "table" and type(velocity) == "table" then
					position.x = position.x + (velocity.x or 0)  * deltaTime
					position.y = position.y + (velocity.y or 0)  * deltaTime
					position.z = position.z + (velocity.z or 0)  * deltaTime
					world:replaceComponent(id, 'Position', position)
				end
			end
		end

		return system
	end

	return Systems
end

return ECS_System

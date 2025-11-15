-- main ecs table
local ECS_System = {} -- table for ecs
ECS_System.__index = ECS_System -- metatable link

-- just copies a table (not deep)
local function createShallowCopy(copiedTable) -- make shallow copy
	local output = {} -- new table
	for key, value in pairs(copiedTable) do -- loop pairs
		output[key] = value -- copy item
	end
	return output -- return copy
end

-- removes one item from an array style table
local function table_removeValue(tab, value) -- remove value
	for i = 1, #tab do -- loop array
		if tab[i] == value then -- if match
			table.remove(tab, i) -- remove it
			return true -- done
		end
	end
	return false -- not found
end

-- tiny signal system cuz roblox events kinda annoying sometimes
local function Signal() -- make signal
	local listeners = {} -- store funcs
	local signal = {} -- signal table

	function signal:connect(func) -- connect func
		if type(func) ~= "function" then error("need function bro") end -- check func
		table.insert(listeners, func) -- add func
		local connection = {} -- conn obj
		function connection:Disconnect() -- disconnect func
			table_removeValue(listeners, func) -- remove func
		end
		return connection -- give conn
	end

	function signal:fire(...) -- fire event
		for i = 1, #listeners do -- loop listeners
			local ok, err = pcall(listeners[i], ...) -- call func
			if not ok then warn("signal callback cooked itself:", err) end -- warn err
		end
	end

	function signal:clear() -- clear all
		for i = #listeners, 1, -1 do listeners[i] = nil end -- wipe
	end

	return signal -- give signal
end

-- entity id factory so ids dont get stupid high
local idPool = {} -- id pool

-- factory block
local nextId = 0 -- next id
local recycled = {} -- recycled ids

function idPool:next() -- get id
	if #recycled > 0 then -- check recycle
		return table.remove(recycled) -- reuse id
	end
	nextId += 1 -- inc id
	return nextId -- return id
end

function idPool:release(id) -- release id
	table.insert(recycled, id) -- add to recycle
end

-- world = main ecs manager
local World = {} -- world table
World.__index = World -- metatable

function World.new(options) -- new world
	options = options or {} -- default opts
	local self = setmetatable({ -- world data
		_entities = {}, -- all entity ids
		_entityComponents = {}, -- entity components
		_components = {}, -- component buckets
		_systems = {}, -- systems list
		_deferred = { -- deferred ops
			add = {}, -- add entity
			remove = {}, -- remove entity
			addComp = {}, -- add comp
			removeComp = {}, -- remove comp
		},
		_isRunning = false, -- running flag
		_queryCache = {}, -- query cache
		_tags = {}, -- tag sets
		_signals = { -- signal set
			entityAdded = Signal(), -- added signal
			entityRemoved = Signal(), -- removed signal
		},
		_profiler = options.profiler or nil, -- profiler
	}, World)
	return self -- give world
end

-- makes sure the component bucket exists
local function ensureComponentsTable(self, componentName) -- ensure bucket
	if not self._components[componentName] then -- check bucket
		self._components[componentName] = {} -- make bucket
	end
end

-- checks if entity matches a query (what components/tags it needs)
local function matchEntitySignature(self, entityId, signature) -- match sig
	local entityComponent = self._entityComponents[entityId] or {} -- get comps

	if signature.all then -- check all
		for _, component in ipairs(signature.all) do -- loop all
			if not entityComponent[component] then return false end -- missing
		end
	end

	if signature.any then -- check any
		local found = false -- found flag
		for _, component in ipairs(signature.any) do -- loop any
			if entityComponent[component] then -- found comp
				found = true break -- break
			end
		end
		if not found then return false end -- none found
	end

	if signature.none then -- check none
		for _, component in ipairs(signature.none) do -- loop none
			if entityComponent[component] then return false end -- reject
		end
	end

	if signature.tags then -- check tags
		for _, tag in ipairs(signature.tags) do -- loop tags
			local tagSet = self._tags[tag] -- get tag set
			if not tagSet or not tagSet[entityId] then return false end -- no tag
		end
	end

	return true -- match ok
end

-- update cached queries (so queries stay fast)
local function updateQueryCache_EntityChange(self, entityId) -- update cache
	for _, value in pairs(self._queryCache) do -- loop cache
		local matches = matchEntitySignature(self, entityId, value.signature) -- check match
		local existed = value.entitiesSet[entityId] ~= nil -- check exist
		if matches and not existed then -- new match
			value.entitiesSet[entityId] = true -- add set
			table.insert(value.entitiesList, entityId) -- add list
		elseif not matches and existed then -- no more match
			value.entitiesSet[entityId] = nil -- remove set
			table_removeValue(value.entitiesList, entityId) -- remove list
		end
	end
end

-- makes an entity (basically just giving it an id and components)
function World:createEntity(initComponents, tags) -- create entity
	initComponents = initComponents or {} -- default
	tags = tags or {} -- default

	local id = idPool:next() -- get id
	self._entities[id] = true -- mark alive
	self._entityComponents[id] = {} -- init comp map

	for name, data in pairs(initComponents) do -- add comps
		ensureComponentsTable(self, name) -- ensure bucket
		self._components[name][id] = data -- add comp
		self._entityComponents[id][name] = true -- mark comp
	end

	for _, tag in ipairs(tags) do -- add tags
		self._tags[tag] = self._tags[tag] or {} -- ensure tag bucket
		self._tags[tag][id] = true -- set tag
	end

	updateQueryCache_EntityChange(self, id) -- update cache
	self._signals.entityAdded:fire(id) -- fire signal
	return id -- give id
end

-- deletes entity & wipes components
function World:destroyEntity(id) -- destroy entity
	if not self._entities[id] then return end -- ignore missing

	if self._isRunning then -- check running
		self._deferred.remove[id] = true return -- defer
	end

	local comps = self._entityComponents[id] or {} -- get comps
	for name in pairs(comps) do -- loop comps
		self._components[name][id] = nil -- remove comp
	end

	self._entityComponents[id] = nil -- wipe comp map

	for _, tagSet in pairs(self._tags) do -- loop tags
		tagSet[id] = nil -- remove tag
	end

	self._entities[id] = nil -- remove entity
	idPool:release(id) -- recycle id
	updateQueryCache_EntityChange(self, id) -- update cache
	self._signals.entityRemoved:fire(id) -- fire signal
end

-- just checks it exists
function World:hasEntity(id) -- check exist
	return self._entities[id] ~= nil -- return bool
end

-- add component to entity
function World:addComponent(entityId, name, data) -- add comp
	if not self._entities[entityId] then error("entity does not exist") end -- check entity

	if self._isRunning then -- check running
		self._deferred.addComp[#self._deferred.addComp + 1] = { entity = entityId, name = name, data = data } -- defer
		return
	end

	ensureComponentsTable(self, name) -- ensure bucket
	self._components[name][entityId] = data -- add comp
	self._entityComponents[entityId][name] = true -- mark comp
	updateQueryCache_EntityChange(self, entityId) -- update cache
end

-- remove component
function World:removeComponent(entityId, name) -- remove comp
	if not self._entities[entityId] then error("entity does not exist") end -- check entity

	if self._isRunning then -- running
		self._deferred.removeComp[#self._deferred.removeComp + 1] = { entity = entityId, name = name } -- defer
		return
	end

	if self._components[name] then -- check bucket
		self._components[name][entityId] = nil -- remove comp
	end
	if self._entityComponents[entityId] then -- check map
		self._entityComponents[entityId][name] = nil -- unmark
	end

	updateQueryCache_EntityChange(self, entityId) -- update cache
end

-- grab component
function World:getComponent(entityId, name) -- get comp
	if not self._entities[entityId] then return nil end -- no entity
	if not self._components[name] then return nil end -- no comp
	return self._components[name][entityId] -- give comp
end

-- replace component (immutable style)
function World:replaceComponent(entityId, name, data) -- replace comp
	ensureComponentsTable(self, name) -- ensure bucket
	self._components[name][entityId] = data -- set comp
	self._entityComponents[entityId][name] = true -- mark comp
	updateQueryCache_EntityChange(self, entityId) -- update cache
end

-- querying system basically finds entities with matching components
function World:query(signature) -- query
	signature = signature or {} -- default
	local key = "" -- key
	if signature.all then key ..= "a" end -- add key
	if signature.any then key ..= "b" end -- add key
	if signature.none then key ..= "c" end -- add key
	if signature.tags then key ..= "d" end -- add key

	local cached = self._queryCache[key] -- get cache
	if cached then return cached.entitiesList end -- return cached

	local result = {} -- new list
	local set = {} -- new set
	for id in pairs(self._entities) do -- loop entities
		if matchEntitySignature(self, id, signature) then -- if match
			set[id] = true -- mark
			table.insert(result, id) -- add
		end
	end

	self._queryCache[key] = { signature = createShallowCopy(signature), entitiesList = result, entitiesSet = set } -- save cache
	return result -- return list
end

-- register a system (runs every update)
function World:registerSystem(system) -- add system
	system.priority = system.priority or 0 -- default prio
	system.name = system.name or "system" -- default name
	table.insert(self._systems, system) -- add sys
	table.sort(self._systems, function(a,b) return a.priority > b.priority end) -- sort
end

-- runs systems, then applies queued changes
function World:update(deltaTime) -- update world
	self._isRunning = true -- mark running
	for _, system in ipairs(self._systems) do -- loop systems
		local ok, err = pcall(system.update, system, self, deltaTime) -- run
		if not ok then warn("system error:", err) end -- warn
	end
	self._isRunning = false -- unmark

	-- apply queued component/entity changes now
	self:_applyDeferred() -- apply defers
end

ECS_System.World = World -- export world

-- basic system example: movement
function ECS_System.Systems() -- make system list
	local Systems = {} -- table

	function Systems.Movement() -- movement sys
		local system = {} -- sys obj
		system.name = "MovementSystem" -- name
		system.priority = 100 -- prio

		function system:update(world, deltaTime) -- update sys
			local list = world:query({ all = {"Position", "Velocity"} }) -- get ents
			for _, id in ipairs(list) do -- loop ents
				local pos = world:getComponent(id, "Position") -- get pos
				local vel = world:getComponent(id, "Velocity") -- get vel
				world:replaceComponent(id, "Position", pos + vel * deltaTime) -- move
			end
		end

		return system -- give sys
	end

	return Systems -- give systems
end

return ECS_System -- export

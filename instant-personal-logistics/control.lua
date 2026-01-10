local logistics = {}

---@type { [integer]: integer }
local player_last_updated = {}

---@class surface_networks
	---@field name string
	---@field networks LuaLogisticNetwork[]

---@param player LuaPlayer?
function logistics.handle_player(player)
	if not player or not logistics.should_process_player(player) then return end

	local logistic_point = player.get_requester_point();
	if logistic_point == nil then return end

	if not logistic_point.enabled and not player.mod_settings["ipl-force-enabled"].value then return end

	if settings.global["ipl-transfer-mode"].value == "local" then
		logistics.transfer_from_local_network(player, logistic_point)
	else
		logistics.transfer_from_all_networks(player, logistic_point)
	end

	player_last_updated[player.index] = game.tick
end

---@param player LuaPlayer
---@param logistic_point LuaLogisticPoint
function logistics.transfer_from_all_networks(player, logistic_point)
	---@type surface_networks[]
	local surfaces = {}

	for surface, networks in pairs(player.force.logistic_networks) do
		if settings.global["ipl-transfer-mode"].value == "interplanetary" or surface == player.physical_surface.name then
			surfaces[#surfaces+1] = { name = surface, networks = networks }
		end
	end

	local request_priority = player.mod_settings["ipl-request-priority"].value

	-- Sorts the networks according to the request_priority
	table.sort(surfaces, function (a, b)
		return (request_priority == "current" and a.name == player.physical_surface.name) or (a.name == request_priority)
	end)

	local requests_fulfilled = true
	for _, surface in pairs(surfaces) do
		for _, network in ipairs(surface.networks) do
			if logistics.is_personal_network(network) then goto next_network end

			requests_fulfilled = logistics.handle_requests(network, player, logistic_point)

			-- Saves a bit of time if there are a lot of logistic networks
			if requests_fulfilled then goto requests_finished end

			::next_network::
		end
	end

	::requests_finished::

	local trash_priority = player.mod_settings["ipl-trash-priority"].value

	-- Sorts the networks according to the trash_priority
	table.sort(surfaces, function (a, b)
		return (trash_priority == "current" and a.name == player.physical_surface.name) or (a.name == trash_priority)
	end)

	local trash_emptied = true
	for _, surface in pairs(surfaces) do
		for _, network in ipairs(surface.networks) do
			if logistics.is_personal_network(network) then goto next_network2 end

			trash_emptied = logistics.handle_trash(network, player)

			-- Saves a bit of time if there are a lot of logistic networks
			if trash_emptied then goto finished end

			::next_network2::
		end
	end

	::finished::

	logistics.post_handle_trash(player, trash_emptied)
end

---@param player LuaPlayer
---@param logistic_point LuaLogisticPoint
function logistics.transfer_from_local_network(player, logistic_point)
	local network = player.physical_surface.find_logistic_network_by_position(player.physical_position, player.force)
	if not network then return end

	logistics.handle_requests(network, player, logistic_point)
	local trash_emptied = logistics.handle_trash(network, player)
	logistics.post_handle_trash(player, trash_emptied)
end

---@param network LuaLogisticNetwork
---@param player LuaPlayer
---@param logistic_point LuaLogisticPoint
function logistics.handle_requests(network, player, logistic_point)
	if not player.mod_settings["ipl-request-enabled"].value then return true end
	if not logistic_point.filters then return true end

	local trash_inv = player.get_inventory(defines.inventory.character_trash)

	-- Every logistic request is fulfilled
	local requests_fulfilled = true

	for _, filter in ipairs(logistic_point.filters) do
		if not filter or not filter.name then goto next_request end

		local existing_count = player.get_item_count({ name = filter.name, quality = filter.quality })

		if not logistics.insert_needed_items(network, player, filter, existing_count) then
			requests_fulfilled = false
		end

		logistics.trash_excess_items(player, filter, existing_count, trash_inv)

		::next_request::
	end

	return requests_fulfilled
end

-- Take the required amount of items from the network and give them to the player
---@param network LuaLogisticNetwork
---@param player LuaPlayer
---@param request CompiledLogisticFilter
---@param existing_count integer
function logistics.insert_needed_items(network, player, request, existing_count)
	if not request.count then return true end

	local needed = request.count - existing_count
	if needed <= 0 then return true end

	-- Lets first check if there are some in the trash inventory
	local trash_inv = player.get_inventory(defines.inventory.character_trash)
	local trash_took = 0
	if trash_inv then
		trash_took = trash_inv.remove({ name = request.name, count = needed, quality = request.quality })
	end

	if trash_inv and trash_took > 0 then
		local t_insterted = player.insert({ name = request.name, count = trash_took, quality = request.quality })
		if trash_took > t_insterted then
			trash_inv.insert({ name = request.name, count = trash_took - t_insterted, quality = request.quality })
		end

		needed = needed - t_insterted
		if needed == 0 then return true end
	end

	local took = network.remove_item({ name = request.name, count = needed, quality = request.quality })
	if took <= 0 then return false end -- Network didn't have this item

	local remaining = took - player.insert({ name = request.name, count = took, quality = request.quality })

	-- Player inventory couldn't fit all the items we took from logistics network so we need to put them back
	if remaining > 0 then
		network.insert({ name = request.name, count = remaining, quality = request.quality })
		return false
	end

	needed = needed - took

	return needed == 0
end

-- Insert items that go over the max amount to trash
---@param player LuaPlayer
---@param request CompiledLogisticFilter
---@param existing_count integer
---@param trash_inv LuaInventory?
function logistics.trash_excess_items(player, request, existing_count, trash_inv)
	if not request.max_count or not trash_inv then return end

	local excess = existing_count - request.max_count
	if excess <= 0 then return end

	local removed = player.remove_item({ name = request.name, count = excess, quality = request.quality })

	if removed > 0 then
		local trash_inserted = trash_inv.insert({ name = request.name, count = removed, quality = request.quality })

		-- Trash inventory couldn't fit all the items we removed so we need to put them back
		if removed > trash_inserted  then
			player.insert({ name = request.name, count = removed - trash_inserted, quality = request.quality })
		end
	end
end

-- Move items from trash slots to the network
---@param network LuaLogisticNetwork
---@param player LuaPlayer
function logistics.handle_trash(network, player)
	if not player.mod_settings["ipl-trash-enabled"].value then return true end

	local player_trash = player.get_inventory(defines.inventory.character_trash)
	if not player_trash then return true end

	local trash_emptied = true

	-- Remove trash
	for i, item in pairs(player_trash.get_contents()) do
		local trash_removed = 0

		local inserted = network.insert({ name = item.name, count = item.count, quality = item.quality }, "storage")
		local to_remove_from_trash = inserted

		if to_remove_from_trash > 0 then
			trash_removed = player_trash.remove({ name = item.name, count = to_remove_from_trash, quality = item.quality })
		end

		-- Trash didn't fit into logistics network
		if trash_removed < item.count then
			trash_emptied = false
		end
	end

	return trash_emptied
end

---@param player LuaPlayer
---@param trash_emptied boolean
function logistics.post_handle_trash(player, trash_emptied)
	if trash_emptied then return end

	if player.mod_settings["ipl-notify-full"].value then
		player.print("Your logistic network(s) are out of storage space!", { skip = defines.print_skip.if_visible })
	end

	if player.mod_settings["ipl-delete-trash-overflow"].value then
		local trash_inv = player.get_inventory(defines.inventory.character_trash)
		if trash_inv then trash_inv.clear() end
	end
end

---@param network LuaLogisticNetwork
function logistics.is_personal_network(network)
	-- Only personal logistic networks have value less than 4294967295, and we don't want to take items from there
	-- There must be a better way to do this but I couldn't find one
	return network.robot_limit < 4294967295
end

---@param player LuaPlayer
function logistics.should_process_player(player)
	if not player.character then return false end
	if player_last_updated[player.index] == game.tick then return false end -- Already updated this tick
	if not player.force.character_logistic_requests then return false end
	return true
end

script.on_event(defines.events.on_player_main_inventory_changed, function (event)
	logistics.handle_player(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_player_ammo_inventory_changed, function (event)
	logistics.handle_player(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_player_cursor_stack_changed, function (event)
	logistics.handle_player(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_entity_logistic_slot_changed, function (event)
	if event.player_index ~= nil then
		logistics.handle_player(game.get_player(event.player_index))
	end
end)

script.on_event(defines.events.on_tick, function (event)
	local frequency = settings.global["ipl-ticks-per-transfer"].value

	if event.tick % frequency ~= 0 then return end

	for _, player in pairs(game.connected_players) do
		logistics.handle_player(player)
	end
end)
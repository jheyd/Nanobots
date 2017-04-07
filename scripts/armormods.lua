-------------------------------------------------------------------------------
--[[armormods]]-- Power Armor module code.
-------------------------------------------------------------------------------
local armormods = {}
require("scripts/armormods-hotkeys")

--TODO: Store this in global and update in on_configuration_changed
--TODO: Remote call for inserting/removing into table
local combat_robots = MOD.config.COMBAT_ROBOTS
local healer_capsules = MOD.config.FOOD

local Position = require("stdlib/area/position")
local min, max, abs, ceil = math.min, math.max, math.abs, math.ceil --luacheck: ignore

-------------------------------------------------------------------------------
--[[Helper functions]]--
-------------------------------------------------------------------------------

-- Loop through equipment grid and return a table of valid equipment tables indexed by equipment name
-- @param entity: the entity object
-- @return table: all equipment - name as key, arrary of named equipment as value
-- @return table: a table of valid equipment with energy in buffer - name as key, array of named equipment as value
-- @return table: shield_level = number, max_shield = number, equipment = array of shields
local function get_valid_equipment(entity)
    local grid = entity.grid
    local all, charged, shields = {}, {}, {equipment = {}}
    if grid and grid.equipment then
        for _, equip in pairs(grid.equipment) do
            all[equip.name] = all[equip.name] or {}
            all[equip.name][#all[equip.name] + 1] = equip
            if equip.type == "energy-shield-equipment" then
                shields.equipment[#shields.equipment + 1] = equip
                shields.shield_level = (shields.shield_level or 0) + (equip.shield or 0)
                shields.max_shield = (shields.max_shield or 0) + (equip.max_shield or 0)
            end
            if equip.energy > 0 then
                charged[equip.name] = charged[equip.name] or {}
                charged[equip.name][#charged[equip.name] + 1] = equip
            end
        end
    end
    return all, charged, shields
end

-- Increment the y position for flying text to keep text from overlapping
-- @param position: position table - start position
-- @return function: increments position all subsequent calls
local function increment_position(position)
    local x = position.x - 1
    local y = position.y - .5
    return function ()
        y=y+0.5
        return {x=x, y=y}
    end
end

-- Is the personal roboport ready and have a radius greater than 0
-- @param entity: the entity object
-- @return bool: personal roboport construction radius > 0
local function is_personal_roboport_ready(entity)
    return entity.logistic_cell and entity.logistic_cell.mobile and entity.logistic_cell.construction_radius > 0
end

--TODO .15 will have a better/more reliable way to get the construction network
-- Does the entity have a personal robort and construction robots. Or is in range of a roboport with construction bots.
-- @param entity: the entity object
-- @param mobile_only: bool just return available construction bots in mobile cell
-- @param stationed_only: bool if mobile only return all construction robots
-- @return number: count of available bots
local function get_bot_counts(entity, mobile_only, stationed_only)
    if entity.logistic_cell then
        if mobile_only then
            if stationed_only then
                return entity.logistic_cell and entity.logistic_cell.stationed_construction_robot_count or 0
            else
                return entity.logistic_network and entity.logistic_network.available_construction_robots or 0
            end
        else
            local count = 0
            count = count + entity.logistic_network.available_construction_robots or 0
            local port = entity.surface.find_entities_filtered{
                type = "roboport",
                area=Position.expand_to_area(entity.position, entity.logistic_cell.construction_radius),
                limit = 1,
                force = entity.force
            }[1]
            count = count + ((port and port.logistic_network and port.logistic_network.available_construction_robots) or 0)
            return count
        end
    else
        return 0
    end
end

local function get_health_capsules(player)
    for name, health in pairs(healer_capsules) do
        if game.item_prototypes[name] and player.remove_item({name=name, count = 1}) > 0 then
            return max(health, 10), game.item_prototypes[name].localised_name or {"nanobots.free-food-unknown"}
        end
    end
    return 10, {"nanobots.free-food"}
end

local function get_best_follower_capsule(player)
    local robot_list = {}
    for _, data in ipairs(combat_robots) do
        local count = game.item_prototypes[data.capsule] and player.get_item_count(data.capsule) or 0
        if count > 0 then
            robot_list[#robot_list+1] = {capsule=data.capsule, unit=data.unit, count=count, qty=data.qty, rank=data.rank}
        end
    end
    return robot_list[1] and robot_list
end

-------------------------------------------------------------------------------
--[[Meat and Potatoes]]--
-------------------------------------------------------------------------------
--At this point player is valid, not afk and has a character

local function get_chip_result_counts(equipment,surface, area, search_type, bot_counter)
    local item_equip = equipment
    local items = equipment and bot_counter(0) > 0 and surface.find_entities_filtered{area=area, type=search_type, limit=200}
    local num_items = items and #items or 0
    local num_chips = items and #equipment or 0
    return item_equip, items, num_items, num_chips, bot_counter
end

local function mark_items_using_eq(player, item_equip, items, num_items, num_item_chips, bot_counter)
    while num_items > 0 and num_item_chips > 0 and bot_counter(0) > 0 do
        local item_chip = items and item_equip[num_item_chips]
        while num_items > 0 and item_chip and item_chip.energy >= 50 do
            local item = items[num_items]
            if item and not item.to_be_deconstructed(player.force) then
                item.order_deconstruction(player.force)
                bot_counter(-1)
                item_chip.energy = item_chip.energy - 50
            end
            num_items = num_items - 1
        end
        num_item_chips = num_item_chips - 1
    end
end

--Mark items for deconstruction if player has roboport
local function process_ready_chips(player, equipment)
    local rad = player.character.logistic_cell.construction_radius
    local area = Position.expand_to_area(player.position, rad)
    local enemy = player.surface.find_nearest_enemy{position=player.position, max_distance=rad+10, force=player.force}
    if not enemy and (equipment["equipment-bot-chip-items"] or equipment["equipment-bot-chip-trees"]) then
        local bots_available = get_bot_counts(player.character)
        if bots_available > 0 then
            local bot_counter = function()
                local count = bots_available
                return function(add_count)
                    count = count + add_count or 0
                    return count
                end
            end
            bot_counter = bot_counter()
            mark_items_using_eq(player, get_chip_result_counts(equipment["equipment-bot-chip-items"], player.surface, area, "item-entity", bot_counter))
            mark_items_using_eq(player, get_chip_result_counts(equipment["equipment-bot-chip-trees"], player.surface, area, "tree", bot_counter))
        end
    end
    if enemy and equipment["equipment-bot-chip-launcher"] then
        local launchers = equipment["equipment-bot-chip-launcher"]
        local num_launchers = #launchers
        local capsule_data = get_best_follower_capsule(player)
        if capsule_data then
            local max_bots = player.force.maximum_following_robot_count + player.character_maximum_following_robot_count_bonus
            local existing = player.surface.count_entities_filtered{area=area, type="combat-robot", force=player.force}
            local next_capsule = 1
            local capsule = capsule_data[next_capsule]
            while capsule and existing < (max_bots - capsule.qty) and capsule.count > 0 and num_launchers > 0 do
                local launcher = launchers[num_launchers]
                while capsule and existing < (max_bots - capsule.qty) and launcher and launcher.energy >= 500 do
                    if player.remove_item({name = capsule.capsule, count=1}) == 1 then
                        player.surface.create_entity{name=capsule.unit, position=player.position, force=player.force, target=player.character}
                        launcher.energy = launcher.energy - 500
                        capsule.count = capsule.count - 1
                        existing = existing + capsule.qty
                        if capsule.count == 0 then
                            next_capsule = next_capsule + 1
                            capsule = capsule_data[next_capsule]
                        end
                    end
                end
                num_launchers = num_launchers - 1
            end
        end
    end
end

local function emergency_heal(player, feeder)
    local count = #feeder
    local pos = increment_position(player.character.position)
    while (player.character.health < (player.character.prototype.max_health * .75)) and count > 0 do
        if feeder[count].energy >= 480 then
            local last_health = player.character.health
            local heal, locale = get_health_capsules(player)
            player.character.health = last_health + heal
            local health_line = {"nanobots.health_line", ceil(abs(player.character.health - last_health)), locale}
            feeder[count].energy = 0
            player.surface.create_entity{name="flying-text", text = health_line, color = defines.colors.green, position = pos()}
        end
        count = count - 1
    end
end
-------------------------------------------------------------------------------
--[[BOT CHIPS]]--
-------------------------------------------------------------------------------
function armormods.prepare_chips(player)
    if player.character.grid and is_personal_roboport_ready(player.character) then
        local _, charged, shields = get_valid_equipment(player.character)
        if charged["equipment-bot-chip-launcher"] or charged["equipment-bot-chip-items"] or charged["equipment-bot-chip-trees"] then
            process_ready_chips(player, charged)
        end
        if charged["equipment-bot-chip-feeder"] then
            emergency_heal(player, charged["equipment-bot-chip-feeder"], shields)
        end
    end
end

return armormods

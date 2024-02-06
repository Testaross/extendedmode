RegisterNetEvent('esx:onPlayerJoined')
AddEventHandler('esx:onPlayerJoined', function()
    local playerId = source
    local identifier, license
    
    for _, v in ipairs(GetPlayerIdentifiers(playerId)) do
        if string.match(v, Config.PrimaryIdentifier) then
            identifier = v
        elseif string.match(v, 'license:') then
            license = v
        end
    end
    
    if not identifier then
        DropPlayerWithErrorMessage(playerId, 'identifier-missing-ingame')
        return
    end
    
    if ESX.GetPlayerFromIdentifier(identifier) then
        DropPlayerWithErrorMessage(playerId, 'identifier-active-ingame', identifier)
        return
    end
    
    MySQL.Async.fetchScalar('SELECT 1 FROM users WHERE identifier = @identifier', {
        ['@identifier'] = identifier
    }, function(result)
        if result then
            LoadESXPlayer(identifier, playerId)
        else
            CreateNewPlayer(identifier, license, playerId)
        end
    end)
end)

function CreateNewPlayer(identifier, license, playerId)
    local accounts = {}
    
    for account, money in pairs(Config.StartingAccountMoney) do
        accounts[account] = money
    end
    
    MySQL.Async.execute('INSERT INTO users (accounts, identifier, license) VALUES (@accounts, @identifier, @license)', {
        ['@accounts'] = json.encode(accounts),
        ['@identifier'] = identifier,
        ['@license'] = license,						
    }, function(rowsChanged)
        if rowsChanged > 0 then
            LoadESXPlayer(identifier, playerId)
        else
            DropPlayerWithErrorMessage(playerId, 'creation-failed')
        end
    end)
end

function LoadESXPlayer(identifier, playerId)
    local userData = {
        accounts = {},
        inventory = {},
        job = {},
        loadout = {},
        playerName = GetPlayerName(playerId),
        weight = 0
    }
    
    MySQL.Async.fetchAll('SELECT accounts, job, job_grade, `group`, loadout, position, inventory FROM users WHERE identifier = @identifier', {
        ['@identifier'] = identifier
    }, function(result)
        if result and #result > 0 then
            ProcessPlayerData(userData, result[1])
        else
            DropPlayerWithErrorMessage(playerId, 'data-missing')
        end
    end)
end

function ProcessPlayerData(userData, data)

    local xPlayer = CreateExtendedPlayer(playerId, identifier, userData.group, userData.accounts, userData.inventory, userData.weight, userData.job, userData.loadout, userData.playerName, userData.coords)
    ESX.Players[playerId] = xPlayer
    TriggerEvent('esx:playerLoaded', playerId, xPlayer)

    xPlayer.triggerEvent('esx:playerLoaded', {
        accounts = xPlayer.getAccounts(),
        coords = xPlayer.getCoords(),
        identifier = xPlayer.getIdentifier(),
        inventory = xPlayer.getInventory(),
        job = xPlayer.getJob(),
        loadout = xPlayer.getLoadout(),
        maxWeight = xPlayer.maxWeight,
        money = xPlayer.getMoney()
    })

    xPlayer.triggerEvent('esx:createMissingPickups', ESX.Pickups)
    xPlayer.triggerEvent('esx:registerSuggestions', ESX.RegisteredCommands)
end

function DropPlayerWithErrorMessage(playerId, errorCode, extraInfo)
    local errorMessage = 'There was an error loading your character!\nError code: ' .. errorCode
    
    if extraInfo then
        errorMessage = errorMessage .. '\n\n' .. extraInfo
    end
    
    DropPlayer(playerId, errorMessage)
end

AddEventHandler('playerConnecting', function(name, setCallback, deferrals)
    deferrals.defer()
    local playerId, identifier = source
    Wait(100)

    for _, v in ipairs(GetPlayerIdentifiers(playerId)) do
        if string.match(v, Config.PrimaryIdentifier) then
            identifier = v
            break
        end
    end

    if not ExM.DatabaseReady then
        deferrals.update("The database is not initialized, please wait...")
        while not ExM.DatabaseReady do
            Wait(1000)
        end
    end

    if identifier then
        if ESX.GetPlayerFromIdentifier(identifier) then
            deferrals.done(('There was an error loading your character!\nError code: identifier-active\n\nThis error is caused by a player on this server who has the same identifier as you have. Make sure you are not playing on the same Rockstar account.\n\nYour Rockstar identifier: %s'):format(identifier))
        else
            deferrals.done()
        end
    else
        deferrals.done('There was an error loading your character!\nError code: identifier-missing\n\nThe cause of this error is not known, your identifier could not be found. Please come back later or report this problem to the server administration team.')
    end
end)

AddEventHandler('playerDropped', function(reason)
    local playerId = source
    local xPlayer = ESX.GetPlayerFromId(playerId)

    if xPlayer then
        TriggerEvent('esx:playerDropped', playerId, reason)

        ESX.SavePlayer(xPlayer, function()
            ESX.Players[playerId] = nil
        end)
    end
end)

RegisterNetEvent('esx:updateCoords')
AddEventHandler('esx:updateCoords', function(coords)
    local xPlayer = ESX.GetPlayerFromId(source)

    if xPlayer then
        xPlayer.updateCoords(coords)
    end
end)

RegisterNetEvent('esx:updateWeaponAmmo')
AddEventHandler('esx:updateWeaponAmmo', function(weaponName, ammoCount)
    local xPlayer = ESX.GetPlayerFromId(source)

    if xPlayer then
        xPlayer.updateWeaponAmmo(weaponName, ammoCount)
    end
end)

RegisterNetEvent('esx:giveInventoryItem')
AddEventHandler('esx:giveInventoryItem', function(target, type, itemName, itemCount)
    local playerId = source
    local sourceXPlayer = ESX.GetPlayerFromId(playerId)
    local targetXPlayer = ESX.GetPlayerFromId(target)

    if type == 'item_standard' then
        local sourceItem = sourceXPlayer.getInventoryItem(itemName)
        local targetItem = targetXPlayer.getInventoryItem(itemName)

        if itemCount > 0 and sourceItem.count >= itemCount then
            if targetXPlayer.canCarryItem(itemName, itemCount) then
                sourceXPlayer.removeInventoryItem(itemName, itemCount)
                targetXPlayer.addInventoryItem(itemName, itemCount)

                sourceXPlayer.showNotification(_U('gave_item', itemCount, sourceItem.label, targetXPlayer.name))
                targetXPlayer.showNotification(_U('received_item', itemCount, sourceItem.label, sourceXPlayer.name))
            else
                sourceXPlayer.showNotification(_U('ex_inv_lim', targetXPlayer.name))
            end
        else
            sourceXPlayer.showNotification(_U('imp_invalid_quantity'))
        end
    elseif type == 'item_account' then
        if itemCount > 0 and sourceXPlayer.getAccount(itemName).money >= itemCount then
            sourceXPlayer.removeAccountMoney(itemName, itemCount)
            targetXPlayer.addAccountMoney(itemName, itemCount)

            sourceXPlayer.showNotification(_U('gave_account_money', ESX.Math.GroupDigits(itemCount), Config.Accounts[itemName], targetXPlayer.name))
            targetXPlayer.showNotification(_U('received_account_money', ESX.Math.GroupDigits(itemCount), Config.Accounts[itemName], sourceXPlayer.name))
        else
            sourceXPlayer.showNotification(_U('imp_invalid_amount'))
        end
    elseif type == 'item_weapon' then
        if sourceXPlayer.hasWeapon(itemName) then
            local weaponLabel = ESX.GetWeaponLabel(itemName)

            if not targetXPlayer.hasWeapon(itemName) then
                local _, weapon = sourceXPlayer.getWeapon(itemName)
                local _, weaponObject = ESX.GetWeapon(itemName)
                itemCount = weapon.ammo

                sourceXPlayer.removeWeapon(itemName)
                targetXPlayer.addWeapon(itemName, itemCount)

                if weaponObject.ammo and itemCount > 0 then
                    local ammoLabel = weaponObject.ammo.label
                    sourceXPlayer.showNotification(_U('gave_weapon_withammo', weaponLabel, itemCount, ammoLabel, targetXPlayer.name))
                    targetXPlayer.showNotification(_U('received_weapon_withammo', weaponLabel, itemCount, ammoLabel, sourceXPlayer.name))
                else
                    sourceXPlayer.showNotification(_U('gave_weapon', weaponLabel, targetXPlayer.name))
                    targetXPlayer.showNotification(_U('received_weapon', weaponLabel, sourceXPlayer.name))
                end
            else
                sourceXPlayer.showNotification(_U('gave_weapon_hasalready', targetXPlayer.name, weaponLabel))
                targetXPlayer.showNotification(_U('received_weapon_hasalready', sourceXPlayer.name, weaponLabel))
            end
        end
    elseif type == 'item_ammo' then
        if sourceXPlayer.hasWeapon(itemName) then
            local weaponNum, weapon = sourceXPlayer.getWeapon(itemName)

            if targetXPlayer.hasWeapon(itemName) then
                local _, weaponObject = ESX.GetWeapon(itemName)

                if weaponObject.ammo then
                    local ammoLabel = weaponObject.ammo.label

                    if weapon.ammo >= itemCount then
                        sourceXPlayer.removeWeaponAmmo(itemName, itemCount)
                        targetXPlayer.addWeaponAmmo(itemName, itemCount)

                        sourceXPlayer.showNotification(_U('gave_weapon_ammo', itemCount, ammoLabel, weapon.label, targetXPlayer.name))
                        targetXPlayer.showNotification(_U('received_weapon_ammo', itemCount, ammoLabel, weapon.label, sourceXPlayer.name))
                    end
                end
            else
                sourceXPlayer.showNotification(_U('gave_weapon_noweapon', targetXPlayer.name))
                targetXPlayer.showNotification(_U('received_weapon_noweapon', sourceXPlayer.name, weapon.label))
            end
        end
    end
end)

RegisterNetEvent('esx:removeInventoryItem')
AddEventHandler('esx:removeInventoryItem', function(type, itemName, itemCount)
    local playerId = source
    local xPlayer = ESX.GetPlayerFromId(source)

    if type == 'item_standard' then
        if itemCount == nil or itemCount < 1 then
            xPlayer.showNotification(_U('imp_invalid_quantity'))
        else
            local xItem = xPlayer.getInventoryItem(itemName)

            if itemCount > xItem.count or xItem.count < 1 then
                xPlayer.showNotification(_U('imp_invalid_quantity'))
            else
                xPlayer.removeInventoryItem(itemName, itemCount)
                local pickupLabel = ('~y~%s~s~ [~b~%s~s~]'):format(xItem.label, itemCount)
                ESX.CreatePickup('item_standard', itemName, itemCount, pickupLabel, playerId)
                xPlayer.showNotification(_U('threw_standard', itemCount, xItem.label))
            end
        end
    elseif type == 'item_account' then
        if itemCount == nil or itemCount < 1 then
            xPlayer.showNotification(_U('imp_invalid_amount'))
        else
            local account = xPlayer.getAccount(itemName)

            if itemCount > account.money or account.money < 1 then
                xPlayer.showNotification(_U('imp_invalid_amount'))
            else
                xPlayer.removeAccountMoney(itemName, itemCount)
                local pickupLabel = ('~y~%s~s~ [~g~%s~s~]'):format(account.label, _U('locale_currency', ESX.Math.GroupDigits(itemCount)))
                ESX.CreatePickup('item_account', itemName, itemCount, pickupLabel, playerId)
                xPlayer.showNotification(_U('threw_account', ESX.Math.GroupDigits(itemCount), string.lower(account.label)))
            end
        end
    elseif type == 'item_weapon' then
        itemName = string.upper(itemName)

        if xPlayer.hasWeapon(itemName) then
            local _, weapon = xPlayer.getWeapon(itemName)
            local _, weaponObject = ESX.GetWeapon(itemName)
            local pickupLabel

            xPlayer.removeWeapon(itemName)

            if weaponObject.ammo and weapon.ammo > 0 then
                local ammoLabel = weaponObject.ammo.label
                pickupLabel = ('~y~%s~s~ [~g~%s~s~]'):format(weapon.label, weapon.ammo)
                xPlayer.showNotification(_U('threw_weapon_ammo', weapon.label, weapon.ammo, ammoLabel))
            else
                pickupLabel = ('~y~%s~s~'):format(weapon.label)
                xPlayer.showNotification(_U('threw_weapon', weapon.label))
            end

            ESX.CreatePickup('item_weapon', itemName, 1, pickupLabel, playerId)
        else
            xPlayer.showNotification(_U('imp_invalid_weapon'))
        end
    end
end)

RegisterNetEvent('esx:useItem')
AddEventHandler('esx:useItem', function(itemName)
    local playerId = source
    local xPlayer = ESX.GetPlayerFromId(playerId)

    if xPlayer then
        local item = xPlayer.getInventoryItem(itemName)

        if item and item.count > 0 then
            TriggerEvent('esx:usedItem', xPlayer, item)

            if item.limit ~= -1 then
                xPlayer.removeInventoryItem(itemName, 1)
            end
        else
            xPlayer.showNotification(_U('imp_invalid_item'))
        end
    end
end)

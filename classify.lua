-- Shared content-classification rules and lookup tables.

local M = {};

-- Tables

M.NAAKUAL_NAMES = {
    ['Colkhab'] = true, ['Tchakka'] = true, ['Achuka'] = true,
    ['Yumcax']  = true, ['Hurkan']  = true, ['Kumhau'] = true,
};

M.DOMAIN_INVASION_ZONES = { [288] = true, [289] = true, [291] = true };  -- Escha Zi'Tah / Ru'Aun / Reisenjima
-- Domain Invasion credits the shared boss while Elvorseal is active; pre-wave mobs need normal attribution.
-- Boss/zone mapping follows BG Wiki.
M.DOMAIN_INVASION_NM_NAMES = { ['Azi Dahaka'] = true, ['Naga Raja'] = true, ['Quetzalcoatl'] = true, ['Mireu'] = true };

--- Multi-zone instances.
M.SHARED_ZONE_GROUP = {
    [275] = 'rakaznar', [133] = 'rakaznar', [189] = 'rakaznar',  -- Outer Ra'Kaznar [U1/U2/U3]
    [183] = 'legion',   [287] = 'legion',                        -- Maquette Abdhaljs-LegionA/B
    [279] = 'woe',      [298] = 'woe',                           -- Walk of Echoes [P1/P2]
};

--- Entry direction -> content, per group.
M.SHARED_ZONE_ENTRY = {
    rakaznar = { [267] = 'Sortie', [274] = 'Vagary' },           -- Kamihr Drifts / Outer Ra'Kaznar
    legion   = { [110] = 'Legion', [249] = 'Ambuscade' },        -- Rolanberry Fields / Mhaura
    woe      = { [247] = 'Odyssey', [248] = 'BCNM' },            -- Rabao / Selbina (WoE HTBF)
};

M.INSTANCE_ZONES = {
    -- [287] = 'Ambuscade' -- shared with Legion, uses source-zone disambiguation
    -- Odyssey: zones 279/298 shared with WoE HTBFs, detected via source-zone disambiguation (see check_zone)
    [292] = 'Omen',           -- Reisenjima Henge
    [78]  = 'Einherjar',      -- Hazhalm Testing Grounds
    [77]  = 'Nyzul',          -- Nyzul Isle (Investigation + Uncharted Survey)
    [73]  = 'Salvage',        -- Zhayolm Remnants (Salvage + Salvage II)
    [74]  = 'Salvage',        -- Arrapago Remnants (Salvage + Salvage II)
    [75]  = 'Salvage',        -- Bhaflau Remnants (Salvage + Salvage II)
    [76]  = 'Salvage',        -- Silver Sea Remnants (Salvage + Salvage II)
    [37]  = 'Limbus',         -- Temenos
    [38]  = 'Limbus',         -- Apollyon
    [48]  = 'Besieged',       -- Al Zahbi: the only mobs that ever exist there are the Besieged waves
    -- Sortie/Vagary (zones 133/275/189) and Legion/Ambuscade (zones 183/287)
    -- use source-zone disambiguation in check_zone(), not INSTANCE_ZONES.
    [55]  = 'Assault',        -- Ilrusi Atoll
    [56]  = 'Assault',        -- Periqia
    [60]  = 'Assault',        -- The Ashu Talif
    [63]  = 'Assault',        -- Lebros Cavern
    [66]  = 'Assault',        -- Mamool Ja Training Grounds
    [69]  = 'Assault',        -- Leujaoam Sanctum
    [182] = 'Walk of Echoes', -- Walk of Echoes (original battlefields)
    [259] = 'Skirmish',       -- Rala Waterways [U] (+ Delve fractures)
    [264] = 'Skirmish',       -- Yorcia Weald [U] (+ Delve fractures)
    [271] = 'Skirmish',       -- Cirdas Caverns [U] (+ Delve fractures)
    [129] = 'Meeble Burrows', -- Ghoyu's Reverie
    [93]  = 'Meeble Burrows', -- Ruhotz Silvermines
};

-- Rules

--- Zone-derived classification.
function M.from_zone(zone_id, zone_name)
    if (zone_id == nil) then return nil; end
    if (zone_name ~= nil and zone_name:match('^Dynamis')) then return { type = 'Dynamis' }; end
    local instance_type = M.INSTANCE_ZONES[zone_id];
    if (instance_type ~= nil) then return { type = instance_type }; end
    return nil;
end

--- Source-zone classification for multi-zone instances.
function M.from_source_zone(zone_id, prev_zone_id)
    local group = M.SHARED_ZONE_GROUP[zone_id];
    if (group == nil) then return nil; end

    local map = M.SHARED_ZONE_ENTRY[group];
    if (map == nil) then return nil; end
    return map[prev_zone_id];
end

--- True when both zones belong to the same multi-zone instance.
function M.same_group(zone_a, zone_b)
    local ga = M.SHARED_ZONE_GROUP[zone_a];
    return ga ~= nil and ga == M.SHARED_ZONE_GROUP[zone_b];
end

--- Buff-gated classification
function M.from_buffs(ct, mob_name, ctx)
    if (ct ~= '' and ct ~= 'Unknown Battlefield') then return ct; end
    if (ctx.has_voidwatcher()) then return 'Voidwatch'; end
    if (ctx.wildskeeper_active and M.NAAKUAL_NAMES[mob_name]) then return 'Wildskeeper'; end
    -- Other Reive Mark kills include Colonization/Lair mobs and obstacles. These are feed-only;
    -- end spoils are recorded separately as Reive runs.
    if (ctx.wildskeeper_active) then
        if (ctx.reive_kind == 'Colonization') then return 'Colonization Reive'; end
        if (ctx.reive_kind == 'Lair') then return 'Lair Reive'; end
        return 'Reive';   -- kind not seen (loaded mid-Reive)
    end
    if (M.DOMAIN_INVASION_ZONES[ctx.zone_id] and ctx.has_elvorseal()) then
        return 'Domain Invasion';
    end
    if (ctx.has_battlefield ~= nil and ctx.has_battlefield()) then return 'BCNM'; end
    return ct;
end

return M;

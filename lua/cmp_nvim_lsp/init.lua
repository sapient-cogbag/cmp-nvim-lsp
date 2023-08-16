local source = require('cmp_nvim_lsp.source')

local M = {}

---Registered client and source mapping.
M.client_source_map = {}

---Setup cmp-nvim-lsp source.
M.setup = function()
  vim.api.nvim_create_autocmd('InsertEnter', {
    group = vim.api.nvim_create_augroup('cmp_nvim_lsp', { clear = true }),
    pattern = '*',
    callback = M._on_insert_enter
  })
end

local if_nil = function(val, default)
  if val == nil then return default end
  return val
end

-- Backported from vim.deprecate (0.9.0+)
local function deprecate(name, alternative, version, plugin, backtrace)
  local message = name .. ' is deprecated'
  plugin = plugin or 'Nvim'
  message = alternative and (message .. ', use ' .. alternative .. ' instead.') or message
  message = message
      .. ' See :h deprecated\nThis function will be removed in '
      .. plugin
      .. ' version '
      .. version
  if vim.notify_once(message, vim.log.levels.WARN) and backtrace ~= false then
    vim.notify(debug.traceback('', 2):sub(2), vim.log.levels.WARN)
  end
end

--- Make nested tables inside the given table with the given nested keys.
--- if a key is present and a table, then it modifies that table in place.
--- if a key is present and *not* a table, then it applies a function to the
---     existing value. If that function returns a table, it fills that in.
---     If it returns nothing, then the function returns early.
---@param top_level_table table Table to modify in place
---@param keypath string[] List of keys to create as nested tables if they don't already exist.
---@param reify? fun(depth: integer, key: string, current_value: any): table?
--- Function to account for the case when a value with a key exists already. If unspecified,
--- it always returns early when that happens. Depth counts from 1 (1 is the top-level,
--- passed in table).
---@param modify_deepest? fun(deepest_table: table) If specified, apply this function
--- to the deepest table - that is, the one inside the last key of the list. This must
--- modify it in place.
---@return boolean did_update If true, then the table was *fully* updated all the way down,
--- and the returned value is the top level table. If false, then somewhere down the
--- chain there was a value that couldn't be replaced with a nested table. In that case,
--- the second returned value is the depth of the first table that could *not* be modified.
---
--- For example, if the top level table failed to have a key with value 5 transformed into a
--- table, the returned depth would be 1 because the top level table was the first to fail
--- to update.
---@return table|integer updated_top_level_table_or_depth
local function make_nested_tables(top_level_table, keypath, reify, modify_deepest)
  -- `nil` indicates a failure of substitution ;3
  reify = reify or function()
    return nil
  end
  -- No modification means we have to do nothing ;p
  modify_deepest = modify_deepest or function() end

  local current_table = top_level_table
  for depth, modification_key in ipairs(keypath) do
    -- Either it becomes a table, or it gets YEETED :)
    if type(current_table[modification_key]) ~= "table" then
      if current_table[modification_key] == nil then
        current_table[modification_key] = {}
      else
        -- It has an actual value that needs to be converted.
        local reified = reify(depth, modification_key, current_table[modification_key])
        if type(reified) ~= "table" then
          -- Failed to convert, so we return as appropriate ^.^
          return false, depth
        end
        current_table[modification_key] = reified
      end
    end
    -- Either it was converted into a table, or we returned with notification of
    -- failure to do so.
    -- Therefore we update the current table
    current_table = current_table[modification_key]
  end
  -- Perform any modifications on the current table (which is the deepest ^.^)
  modify_deepest(current_table)
  return true, top_level_table
end

--- Extend the first list with elements from the second that aren't already in it.
--- May not be particularly efficient.
--- Also returns the output list, even though it does modify in place ^.^
--- May be helpful in cases where you aren't sure if an API you are gluing things on the end of
--- requires uniqueness.
---
--- @generic T
--- @param destination `T`[]
--- @param extra_items `T`[]
--- @return `T`[] destination
local function list_unique_extend(destination, extra_items)
  for _idx, new_item in ipairs(extra_items) do
    if not vim.list_contains(destination, new_item) then
      destination[#destination + 1] = new_item
    end
  end
  return destination
end

--- Apply an override option to the given config table.
---
---@param config_table table Table to modify
---@param override_spec {[string]: nil|"use_existing"|"use_if_nil"|{ new_value: any? }}
--- Override specification.
---@param override_key string Key in the override specification that we want to examine ^.^
---@param cmp_value any The value to actually replace it with when doing use_existing
---@param table_key string? If specified, the actual key inside the config table to
--- change. If unspecified, this just uses the override key.
local function apply_override(config_table, override_spec, override_key, cmp_value, table_key)
  local config_table_key = table_key or override_key
  local curr_config_value = config_table[config_table_key]
  local spec_for_override_key = override_spec[override_key]
  if spec_for_override_key == nil then
    config_table[config_table_key] = cmp_value
  elseif spec_for_override_key == "use_if_nil" and curr_config_value == nil then
    config_table[config_table_key] = cmp_value
  elseif spec_for_override_key == "use_existing" then
    return
  elseif type(spec_for_override_key) == "table" then
    config_table[config_table_key] = spec_for_override_key.new_value
  end
end

--- Apply a *structured* override option.
--- Some override options are conceptually more than just setting a value in a map.
---
--- In this case, we allow arbitrary functions for modification instead. For instance,
--- this lets us conditionally *add* to a set of values rather than overriding what
--- already exists - it's additive to existing capabilities, rather than being destructive
--- ^.^
---
--- This provides sensible extensions to the the existing apply_override mechanism.
---
---@param config_table table Table to modify
---@param override_spec {[string]: nil|"use_existing"|"use_if_nil"|{ new_value: any? }}
--- Override specification. In this case, the *conditions for applying the change* (calling the
--- function) remain the same, except that the cmp_value parameter, or new_value parameter
--- as specified, are passed into the function where they would otherwise have been
--- merely assigned directly.
---@param override_key string Key in the override specification that we want to examine ^.^
---@param applicator fun( existing_value: any?, value: any?): any
--- Function to apply the change. It is supplied with two arguments:
---  * The existing value, if any, that is present currently in the table for the given
---     key.
---  * The value - either cmp_value as supplied to this function, when the override spec
---     is nil or "use_if_nil", or the new, supplied value, if it is a table mode ^.^
--- This function returns the new value to assign to the key in the config table.
--- If modifying the existing_value parameter in place, simply return the existing_value parameter ;p.
--- This function is only called in the same places as normal changes (without applicators), so you
--- need do no extra checking on that front.
---@param cmp_value any? The value that makes *conceptual* sense for this modification.
--- For instance, the set of values to inject into another set ^.^
---@param table_key string? If specified, the actual key inside the config table to
--- check for information. If not specified, it defaults to the override key.
local function apply_advanced_override(config_table, override_spec, override_key, applicator, cmp_value, table_key)
  local config_table_key = table_key or override_key
  local curr_config_value = config_table[config_table_key]
  local spec_for_override_key = override_spec[override_key]

  if spec_for_override_key == nil then
    config_table[config_table_key] = applicator(curr_config_value, cmp_value)
  elseif spec_for_override_key == "use_if_nil" and curr_config_value == nil then
    config_table[config_table_key] = applicator(curr_config_value, cmp_value)
  elseif spec_for_override_key == "use_existing" then
    return
  elseif type(spec_for_override_key) == "table" then
    config_table[config_table_key] = applicator(curr_config_value, spec_for_override_key.new_value)
  end
end


--- Modify some LSP client capabilities to enable those that are needed for cmp_nvim_lsp.
--- For example, turning LSP snippet capability on, as cmp requires a snippet engine.
--- This attempts to do the minimum possible modification - vim.lsp is constantly being
--- updated with new capabilities, and overwriting them as in the old default_capabilities
--- function can cause significant functionality degradation.
---@param override? {[string]: nil|"use_existing"|"use_if_nil"|{ new_value: any? }}
--- Precisely control whether:
--- * This function should update the functionality (this is the case when the value of
---   a key is unspecified)
--- * This function should not modify the existing key for the functionality in the
---   capabilities table ("use_existing")
--- * This function should mofiy the existing key for the functionality in the
---   capabilities table, but only if it is currently nil/unset ("use_if_nil").
--- * This function should replace the value with a new one (provide a table, and the
---   entry "new_value" will be extracted and applied to the relevant functionality
---   key)
---
---@param capabilities? table The actual LSP capabilities table. If not specified, this will
--- construct a new one with vim.lsp.protocol.make_client_capabilities() and work on that.
--- Else, it will modify it in place (and return it)
---
---@return table capabilities The modified capabilities table. If you didn't pass one in, this is still fine, it will
--- work on top of the default. If you did pass one in, it's just returned back to you.
M.modify_capabilities = function(override, capabilities)
  override = override or {}
  ---@type table
  capabilities = capabilities or vim.lsp.protocol.make_client_capabilities()
  local did_update

  did_update, capabilities = make_nested_tables(
    capabilities,
    { "textDocument", "completion", "completionItem" },
    nil,
    function(completionItem)
      apply_override(completionItem, override, "snippetSupport", true)
      apply_override(completionItem, override, "commitCharactersSupport", true)
      apply_override(completionItem, override, "deprecatedSupport", true)
      apply_override(completionItem, override, "preselectSupport", true)
      apply_advanced_override(completionItem, override, "tagSupport", function(supported_tags, extra_tags)
        supported_tags = supported_tags or {}
        supported_tags.valueSet = list_unique_extend(supported_tags.valueSet or {}, extra_tags)
        return supported_tags
      end, {
        1,         -- tag for deprecated
      })
      apply_override(completionItem, override, "insertReplaceSupport", true)
      apply_advanced_override(completionItem, override, "resolveSupport",
        function(resolvables, additional_properties)
          resolvables = resolvables or {}
          resolvables.properties = list_unique_extend(resolvables.properties or {}, additional_properties)
          return resolvables
        end, {
          "documentation",
          "detail",
          "additionalTextEdits",
          "sortText",
          "filterText",
          "insertText",
          "textEdit",
          "insertTextFormat",
          "insertTextMode"
        })
      apply_advanced_override(completionItem, override, "insertTextModeSupport", function(textmodes, extra_modes)
        textmodes = textmodes or {}
        textmodes.valueSet = list_unique_extend(textmodes.valueSet or {}, extra_modes)
        return textmodes
      end, {
        1,         -- asIs
        2,         -- adjustIndentation
      })
      apply_override(completionItem, override, "labelDetailsSupport", true)
    end
  )

  if not did_update then error("Failed to modify capabilities (completionItem)") end

  -- We still go for nested table construction for these simpler parameters. It provides good
  -- segmentation of this function.
  -- @type capabilities table
  did_update, capabilities = make_nested_tables(
    capabilities,
    { "textDocument", "completion" },
    nil,
    function(completion)
      -- Note the use of the same key as earlier - snippetSupport controls multiple capabilities ^.^
      apply_override(completion, override, "snippetSupport", true)
      apply_override(completion, override, "insertTextMode", 1)
      apply_advanced_override(completion, override, "completionList",
        function(completion_list_specifier, extra_defaults)
          completion_list_specifier = completion_list_specifier or {}
          -- I'm pretty sure this is some kind of ordered list. As such, I'm gluing these defaults on the end instead of
          -- doing a unique extend ^.^
          completion_list_specifier.itemDefaults = vim.list_extend(
            completion_list_specifier.itemDefaults or {}, extra_defaults)
          return completion_list_specifier
        end, {
          'commitCharacters',
          'editRange',
          'insertTextFormat',
          'insertTextMode',
          'data',

        })
    end
  )

  if not did_update then
    error("Failed to modify capabilities (completion)")
  end

  return capabilities
end

M.default_capabilities = function(override)
  local _deprecate = vim.deprecate or deprecate
  local override = override or {}

  --- Override under the new system
  local value_substituted_override = {}

  --- @type { [string]: string } map of keys inside the old overrides to
  --- a string that should then be retrieved as a key from the old override value
  --- to get the new, "conceptual" override value.
  local unpack_keys = {}
  unpack_keys.tagSupport = "valueSet"
  unpack_keys.resolveSupport = "properties"
  unpack_keys.insertTextModeSupport = "valueSet"
  unpack_keys.completionList = "itemDefaults"


  for k, new_value_if_not_nil in pairs(override) do
    -- pairs only iterates over non-nil items ^.^
    -- Because nil keys imply substituting the nvim_lsp defaults, it works like if_nil does.
    -- However we have to unwrap some special parts of it to work with the new "conceptual" system
    -- of applying modifications ^.^
    value_substituted_override[k] = { new_value = new_value_if_not_nil }
    if unpack_keys[k] ~= nil then
      value_substituted_override[k] = { new_value = new_value_if_not_nil[unpack_keys[k]] }
    end
  end

  _deprecate('cmp_nvim_lsp.default_capabilities', 'cmp_nvim_lsp.modify_capabilities', '1.0.0', 'cmp-nvim-lsp')
  return M.modify_capabilities(value_substituted_override)
end

---Backwards compatibility
M.update_capabilities = function(_, override)
  local _deprecate = vim.deprecate or deprecate
  _deprecate('cmp_nvim_lsp.update_capabilities', 'cmp_nvim_lsp.modify_capabilities', '1.0.0', 'cmp-nvim-lsp')
  return M.default_capabilities(override)
end


---Refresh sources on InsertEnter.
M._on_insert_enter = function()
  local cmp = require('cmp')

  local allowed_clients = {}

  -- register all active clients.
  for _, client in ipairs(vim.lsp.get_active_clients()) do
    allowed_clients[client.id] = client
    if not M.client_source_map[client.id] then
      local s = source.new(client)
      if s:is_available() then
        M.client_source_map[client.id] = cmp.register_source('nvim_lsp', s)
      end
    end
  end

  -- register all buffer clients (early register before activation)
  for _, client in ipairs(vim.lsp.buf_get_clients(0)) do
    allowed_clients[client.id] = client
    if not M.client_source_map[client.id] then
      local s = source.new(client)
      if s:is_available() then
        M.client_source_map[client.id] = cmp.register_source('nvim_lsp', s)
      end
    end
  end

  -- unregister stopped/detached clients.
  for client_id, source_id in pairs(M.client_source_map) do
    if not allowed_clients[client_id] or allowed_clients[client_id]:is_stopped() then
      cmp.unregister_source(source_id)
      M.client_source_map[client_id] = nil
    end
  end
end

return M

---@class VirtualIndent
---@field private _ns_id number extmarks namespace id
---@field private _headline_lib any Treesitter headline library
---@field private _bufnr integer Buffer VirtualIndent is attached to
---@field private _attached boolean Whether or not VirtualIndent is attached for its buffer
---@field private _bufnrs {integer: boolean} Buffers with VirtualIndent attached
---@field private _timer uv_timer_t Timer used for tracking `org_indent_mode`
---@field private _watcher_running boolean Whether or not VirtualIndent is reacting to `vim.borg_indent_mode`
local VirtualIndent = {
  _ns_id = vim.api.nvim_create_namespace('orgmode.ui.indent'),
  _bufnrs = {},
}

--- Creates a new instance of VirtualIndent for a given buffer or returns the existing instance if
--- one exists
---@param bufnr? integer Buffer to use for VirtualIndent when attached
---@return VirtualIndent
function VirtualIndent:new(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local curr_instance = VirtualIndent._bufnrs[bufnr]
  if curr_instance then
    return curr_instance
  end

  local new = {}
  setmetatable(new, self)
  self.__index = self

  new._bufnr = bufnr
  new._headline_lib = require('orgmode.treesitter.headline')
  new._attached = false
  VirtualIndent._bufnrs[new._bufnr] = new
  new._watcher_running = false
  new._timer = vim.uv.new_timer()
  return new
end

function VirtualIndent:_delete_old_extmarks(start_line, end_line)
  local old_extmarks = vim.api.nvim_buf_get_extmarks(
    self._bufnr,
    self._ns_id,
    { start_line, 0 },
    { end_line, 0 },
    { type = 'virt_text' }
  )
  for _, ext in ipairs(old_extmarks) do
    vim.api.nvim_buf_del_extmark(self._bufnr, self._ns_id, ext[1])
  end
end

function VirtualIndent:_get_indent_size(line)
  local headline = self._headline_lib.from_cursor({ line + 1, 1 })

  if headline then
    local headline_line, _, _ = headline.headline:start()

    if headline_line ~= line then
      return headline:level() + 1
    end
  end

  return 0
end

---@param start_line number start line number to set the indentation, 0-based inclusive
---@param end_line number end line number to set the indentation, 0-based inclusive
---@param ignore_ts? boolean whether or not to skip the treesitter start & end lookup
function VirtualIndent:set_indent(start_line, end_line, ignore_ts)
  ignore_ts = ignore_ts or false
  local headline = self._headline_lib.from_cursor({ start_line + 1, 1 })
  if headline and not ignore_ts then
    local parent = headline.headline:parent()
    start_line = parent:start()
    end_line = parent:end_()
  end
  if start_line > 0 then
    start_line = start_line - 1
  end
  self:_delete_old_extmarks(start_line, end_line)
  for line = start_line, end_line do
    local indent = self:_get_indent_size(line)

    if indent > 0 then
      -- NOTE: `ephemeral = true` is not implemented for `inline` virt_text_pos :(
      vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_id, line, 0, {
        virt_text = { { string.rep(' ', indent), 'OrgIndent' } },
        virt_text_pos = 'inline',
        right_gravity = false,
      })
    end
  end
end

--- Begins a timer to check `vim.b.org_indent_mode` if `vim.b.org_indent_mode` is not already being
--- monitored
function VirtualIndent:start_watch_org_indent()
  if not self._watcher_running then
    self._watcher_running = true
    self._timer:start(
      50,
      50,
      vim.schedule_wrap(function()
        local success, indent_mode_enabled = pcall(vim.api.nvim_buf_get_var, self._bufnr, 'org_indent_mode')
        if success and indent_mode_enabled then
          if not self._attached then
            self:attach()
          end
        elseif self._attached then
          self:detach()
        end
      end)
    )
  end
end

--- Stops the current VirtualIndent instance from reacting to changes in `vim.b.org_indent_mode`
function VirtualIndent:stop_watch_org_indent()
  self._watcher_running = false
  self._timer:stop()
end

--- Enables virtual indentation in registered buffer
function VirtualIndent:attach()
  self._attached = true
  self:set_indent(0, vim.api.nvim_buf_line_count(self._bufnr) - 1, true)
  self:start_watch_org_indent()

  vim.api.nvim_buf_attach(self._bufnr, false, {
    on_lines = function(_, _, _, start_line, _, end_line)
      if not self._attached then
        return true
      end
      -- HACK: By calling `set_indent` twice, once synchronously and once in `vim.schedule` we get smooth usage of the
      -- virtual indent in most cases and still properly handle undo redo. Unfortunately this is called *early* when
      -- `undo` or `redo` is used causing the padding to be incorrect for some headlines.
      self:set_indent(start_line, end_line)
      vim.schedule(function()
        self:set_indent(start_line, end_line)
      end)
    end,
  })
end

function VirtualIndent:detach()
  self._attached = false
  vim.api.nvim_buf_set_var(self._bufnr, 'org_indent_mode', false)
  self:_delete_old_extmarks(0, vim.api.nvim_buf_line_count(self._bufnr) - 1)
end

return VirtualIndent
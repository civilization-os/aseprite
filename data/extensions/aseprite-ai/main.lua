local defaults = {
  ws_url = "ws://127.0.0.1:8765",
  auto_connect = false,
  preview_layer_name = "AI Preview",
  request_timeout_ms = 30000,
}

local state = {
  ws = nil,
  connected = false,
  initialized = false,
  pending_request = nil,
  request_timer = nil,
  next_id = 1,
  temp_id = 1,
  preview = nil,
}

local function plugin_prefs(plugin)
  local p = plugin.preferences
  if p.ws_url == nil then p.ws_url = defaults.ws_url end
  if p.auto_connect == nil then p.auto_connect = defaults.auto_connect end
  if p.preview_layer_name == nil then p.preview_layer_name = defaults.preview_layer_name end
  if p.request_timeout_ms == nil then p.request_timeout_ms = defaults.request_timeout_ms end
  return p
end

local function active_sprite()
  return app.sprite
end

local function active_frame_number()
  return app.frame and app.frame.frameNumber or 1
end

local function has_selection(sprite)
  return sprite and sprite.selection and not sprite.selection.isEmpty
end

local function get_selection_bounds(sprite)
  if not has_selection(sprite) then
    return nil
  end
  local b = sprite.selection.bounds
  return { x=b.x, y=b.y, width=b.width, height=b.height }
end

local function palette_to_hex_list(sprite)
  local result = {}
  if not sprite or not sprite.palettes or #sprite.palettes == 0 then
    return result
  end

  local frame_number = active_frame_number()
  local palette = sprite.palettes[math.min(frame_number, #sprite.palettes)]
  if not palette then
    palette = sprite.palettes[1]
  end

  for i = 0, #palette-1 do
    local c = palette:getColor(i)
    result[#result+1] = string.format("#%02X%02X%02X%02X", c.red, c.green, c.blue, c.alpha)
  end
  return result
end

local function next_temp_file(ext)
  local path = app.fs.joinPath(app.fs.tempPath, string.format("aseprite-ai-%d.%s", state.temp_id, ext))
  state.temp_id = state.temp_id + 1
  return path
end

local function stop_request_timer()
  if state.request_timer and state.request_timer.isRunning then
    state.request_timer:stop()
  end
  state.request_timer = nil
end

local function close_socket(send_close)
  stop_request_timer()
  state.pending_request = nil
  state.connected = false
  state.initialized = false

  local ws = state.ws
  state.ws = nil
  if send_close and ws then
    pcall(function() ws:close() end)
  end
end

local function ensure_connected()
  return state.ws and state.connected and state.initialized
end

local function can_generate()
  return active_sprite() ~= nil and app.layer ~= nil and app.layer.isImage
end

local function can_apply_preview()
  return state.preview ~= nil and state.preview.sprite ~= nil and state.preview.layer ~= nil
end

local function layer_by_name(sprite, name)
  for _, layer in ipairs(sprite.layers) do
    if layer.name == name then
      return layer
    end
  end
  return nil
end

local function export_reference_image(sprite, mode)
  if not sprite or not app.layer or not app.layer.isImage or not app.image then
    return nil
  end

  local image = app.image:clone()
  if mode == "edit" and has_selection(sprite) then
    local bounds = sprite.selection.bounds
    image = Image(image, Rectangle(bounds.x, bounds.y, bounds.width, bounds.height))
  end

  local path = next_temp_file("png")
  image:saveAs(path)
  return base64.encode(app.fs.readFile(path))
end

local function build_tool_arguments(mode, prompt)
  local sprite = active_sprite()
  return {
    prompt = prompt,
    sprite_size = {
      width = sprite.width,
      height = sprite.height,
    },
    selection_bounds = get_selection_bounds(sprite),
    palette = palette_to_hex_list(sprite),
    active_layer_name = app.layer and app.layer.name or "",
    color_mode = sprite.colorMode,
    has_selection = has_selection(sprite),
    reference_image = export_reference_image(sprite, mode),
  }
end

local function show_message(text)
  app.alert(text)
end

local function send_json(payload)
  state.ws:sendText(json.encode(payload))
end

local function parse_tool_result(result)
  if result and result.structuredContent then
    return result.structuredContent
  end
  if result and result.content and result.content[1] and result.content[1].text then
    return json.decode(result.content[1].text)
  end
  return result
end

local function import_png_image(encoded_png)
  local path = next_temp_file("png")
  app.fs.writeFile(path, base64.decode(encoded_png))
  return Image{ fromFile=path }
end

local function prepare_preview_image(sprite)
  local preview = Image(sprite.spec)
  preview:clear()
  return preview
end

local function show_preview(plugin, request, response)
  local sprite = request.sprite
  if not sprite then
    error("No active sprite")
  end

  local imported = import_png_image(response.image_png_base64)
  local preview_image = prepare_preview_image(sprite)
  local target_layer = request.layer
  local pos_x = 0
  local pos_y = 0

  if request.mode == "edit" then
    local bounds = request.selection_bounds
    if bounds then
      if imported.width ~= bounds.width or imported.height ~= bounds.height then
        error("Returned image size must match the current selection")
      end
      pos_x = bounds.x
      pos_y = bounds.y
    else
      if imported.width ~= sprite.width or imported.height ~= sprite.height then
        error("Edit Selection without a selection must return a full sprite image")
      end
    end
  else
    pos_x = math.floor((sprite.width - imported.width) / 2)
    pos_y = math.floor((sprite.height - imported.height) / 2)
  end

  preview_image:drawImage(imported, pos_x, pos_y)

  app.transaction("AI Preview", function()
    local preview_name = plugin_prefs(plugin).preview_layer_name
    local existing = layer_by_name(sprite, preview_name)
    if existing then
      sprite:deleteLayer(existing)
    end

    local preview_layer = sprite:newLayer()
    preview_layer.name = preview_name
    sprite:newCel(preview_layer, request.frame_number, preview_image, Point(0, 0))

    state.preview = {
      sprite = sprite,
      layer = preview_layer,
      target_layer = target_layer,
      frame_number = request.frame_number,
    }
  end)
  app.refresh()
end

local function finish_request(payload, plugin)
  local pending = state.pending_request
  state.pending_request = nil
  stop_request_timer()

  if payload.error then
    show_message("AI request failed: " .. (payload.error.message or "Unknown error"))
    return
  end

  local result = parse_tool_result(payload.result or {})
  if not result or not result.image_png_base64 then
    show_message("AI request failed: missing image_png_base64 in response")
    return
  end

  local ok, err = pcall(function()
    show_preview(plugin, pending, result)
  end)
  if not ok then
    show_message("AI request failed: " .. tostring(err))
  end
end

local function begin_request(plugin, tool_name, mode, prompt)
  if not ensure_connected() then
    show_message("AI bridge is not connected. Use AI > Connect first.")
    return
  end
  if state.pending_request then
    show_message("An AI request is already running.")
    return
  end

  local request_id = state.next_id
  state.next_id = state.next_id + 1
  state.pending_request = {
    id = request_id,
    mode = mode,
    sprite = active_sprite(),
    layer = app.layer,
    frame_number = active_frame_number(),
    selection_bounds = get_selection_bounds(active_sprite()),
  }

  state.request_timer = Timer{
    interval = (tonumber(plugin_prefs(plugin).request_timeout_ms) or defaults.request_timeout_ms) / 1000.0,
    ontick = function()
      stop_request_timer()
      if state.pending_request and state.pending_request.id == request_id then
        state.pending_request = nil
        show_message("AI request timed out.")
      end
    end
  }
  state.request_timer:start()

  send_json({
    jsonrpc = "2.0",
    id = request_id,
    method = "tools/call",
    params = {
      name = tool_name,
      arguments = build_tool_arguments(mode, prompt),
    }
  })
end

local function prompt_dialog(title, note)
  local dlg = Dialog(title)
  dlg:label{ id="note", text=note }
  dlg:separator()
  dlg:entry{ id="prompt", label="Prompt", text="" }
  dlg:button{ id="ok", text="OK" }
  dlg:button{ id="cancel", text="Cancel" }
  dlg:show{ wait=true }
  local data = dlg.data
  if data.ok then
    return data.prompt
  end
  return nil
end

local function settings_dialog(plugin)
  local p = plugin_prefs(plugin)
  local dlg = Dialog("AI Settings")
  dlg:entry{ id="ws_url", label="WebSocket URL", text=tostring(p.ws_url) }
  dlg:check{ id="auto_connect", label="Auto Connect", selected=p.auto_connect and true or false }
  dlg:entry{ id="preview_layer_name", label="Preview Layer", text=tostring(p.preview_layer_name) }
  dlg:entry{ id="request_timeout_ms", label="Timeout (ms)", text=tostring(p.request_timeout_ms) }
  dlg:button{ id="ok", text="Save" }
  dlg:button{ id="cancel", text="Cancel" }
  dlg:show{ wait=true }

  local data = dlg.data
  if not data.ok then
    return
  end

  p.ws_url = data.ws_url
  p.auto_connect = data.auto_connect
  p.preview_layer_name = data.preview_layer_name
  p.request_timeout_ms = tonumber(data.request_timeout_ms) or defaults.request_timeout_ms
end

local function connect_socket(plugin)
  if state.ws then
    close_socket(true)
    show_message("AI bridge disconnected.")
    return
  end

  if not WebSocket then
    show_message("This build does not include WebSocket scripting support.")
    return
  end

  local prefs = plugin_prefs(plugin)
  state.ws = WebSocket{
    url = prefs.ws_url,
    onreceive = function(message_type, data, err)
      if message_type == WebSocketMessageType.OPEN then
        state.connected = true
        local init_id = state.next_id
        state.next_id = state.next_id + 1
        send_json({
          jsonrpc = "2.0",
          id = init_id,
          method = "initialize",
          params = {
            protocolVersion = "2024-11-05",
            clientInfo = {
              name = "aseprite-ai-bridge",
              version = "1.0"
            },
            capabilities = {}
          }
        })
        return
      end

      if message_type == WebSocketMessageType.CLOSE then
        close_socket(false)
        show_message("AI bridge disconnected.")
        return
      end

      if message_type == WebSocketMessageType.ERROR then
        local message = "AI bridge connection failed."
        if err and #err > 0 then
          message = message .. "\n" .. err
        end
        close_socket(false)
        show_message(message)
        return
      end

      if message_type ~= WebSocketMessageType.TEXT then
        return
      end

      local ok, payload = pcall(function() return json.decode(data) end)
      if not ok then
        return
      end

      if not state.initialized and payload.id and payload.result and payload.result.protocolVersion then
        state.initialized = true
        send_json({
          jsonrpc = "2.0",
          method = "notifications/initialized",
          params = {}
        })
        show_message("AI bridge connected.")
        return
      end

      if state.pending_request and payload.id and tonumber(payload.id) == state.pending_request.id then
        finish_request(payload, plugin)
      end
    end
  }

  state.ws:connect()
end

local function apply_preview()
  if not can_apply_preview() then
    show_message("No AI preview is available.")
    return
  end

  local preview = state.preview
  local ok, err = pcall(function()
    app.transaction("Apply AI Preview", function()
      local preview_cel = preview.layer:cel(preview.frame_number)
      if not preview_cel then
        error("Missing preview cel")
      end

      local target_cel = preview.target_layer:cel(preview.frame_number)
      if not target_cel then
        local image = Image(preview.sprite.spec)
        image:clear()
        target_cel = preview.sprite:newCel(preview.target_layer, preview.frame_number, image, Point(0, 0))
      end

      local merged = target_cel.image:clone()
      merged:drawImage(preview_cel.image, 0, 0)
      target_cel.image = merged
      preview.sprite:deleteLayer(preview.layer)
      state.preview = nil
    end)
    app.refresh()
  end)

  if not ok then
    show_message("Apply Preview failed: " .. tostring(err))
  end
end

local function discard_preview()
  if not can_apply_preview() then
    show_message("No AI preview is available.")
    return
  end

  local ok, err = pcall(function()
    app.transaction("Discard AI Preview", function()
      state.preview.sprite:deleteLayer(state.preview.layer)
      state.preview = nil
    end)
    app.refresh()
  end)

  if not ok then
    show_message("Discard Preview failed: " .. tostring(err))
  end
end

function init(plugin)
  plugin_prefs(plugin)

  plugin:newCommand{
    id = "AIConnect",
    title = "Connect",
    group = "ai_connection",
    onclick = function() connect_socket(plugin) end
  }

  plugin:newCommand{
    id = "AISettings",
    title = "Settings",
    group = "ai_settings",
    onclick = function() settings_dialog(plugin) end
  }

  plugin:newCommand{
    id = "AIGenerateFromPrompt",
    title = "Generate From Prompt",
    group = "ai_generation",
    onenabled = function() return can_generate() end,
    onclick = function()
      local prompt = prompt_dialog("Generate From Prompt", "Generate a preview for the current sprite.")
      if prompt and #prompt > 0 then
        begin_request(plugin, "aseprite.generate_image", "generate", prompt)
      end
    end
  }

  plugin:newCommand{
    id = "AIEditSelection",
    title = "Edit Selection",
    group = "ai_generation",
    onenabled = function() return can_generate() end,
    onclick = function()
      local note = has_selection(active_sprite())
        and "Edit the current selection."
        or "No selection found. The whole current layer will be edited."
      local prompt = prompt_dialog("Edit Selection", note)
      if prompt and #prompt > 0 then
        begin_request(plugin, "aseprite.edit_selection", "edit", prompt)
      end
    end
  }

  plugin:newCommand{
    id = "AIApplyPreview",
    title = "Apply Preview",
    group = "ai_preview",
    onenabled = function() return can_apply_preview() end,
    onclick = function() apply_preview() end
  }

  plugin:newCommand{
    id = "AIDiscardPreview",
    title = "Discard Preview",
    group = "ai_preview",
    onenabled = function() return can_apply_preview() end,
    onclick = function() discard_preview() end
  }

  if plugin_prefs(plugin).auto_connect then
    connect_socket(plugin)
  end
end

function exit(plugin)
  close_socket(true)
end

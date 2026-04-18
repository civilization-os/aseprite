-- Copyright (C) 2026  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

do
  local ok_connect = pcall(function() return app.command.AIConnect end)
  local ok_generate = pcall(function() return app.command.AIGenerateFromPrompt end)
  local ok_edit = pcall(function() return app.command.AIEditSelection end)
  local ok_apply = pcall(function() return app.command.AIApplyPreview end)
  local ok_discard = pcall(function() return app.command.AIDiscardPreview end)
  local ok_settings = pcall(function() return app.command.AISettings end)

  assert(ok_connect)
  assert(ok_generate)
  assert(ok_edit)
  assert(ok_apply)
  assert(ok_discard)
  assert(ok_settings)
end

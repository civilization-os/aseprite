-- Copyright (C) 2026  Igara Studio S.A.
--
-- This file is released under the terms of the MIT license.
-- Read LICENSE.txt for more information.

do
  local raw = string.char(0, 1, 2, 3, 250, 251, 252) .. "Aseprite"
  local encoded = base64.encode(raw)
  assert(encoded == "AAECA/r7/EFzZXByaXRl")
  local decoded = base64.decode(encoded)
  assert(decoded == raw)
end

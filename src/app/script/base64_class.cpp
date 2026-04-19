// Aseprite
// Copyright (C) 2026  Igara Studio S.A.
//
// This program is distributed under the terms of
// the End-User License Agreement for Aseprite.

#ifdef HAVE_CONFIG_H
  #include "config.h"
#endif

#include "app/script/luacpp.h"
#include "base/base64.h"

namespace app { namespace script {

namespace {

struct Base64 {};

int Base64_encode(lua_State* L)
{
  size_t len = 0;
  const char* data = luaL_checklstring(L, 1, &len);
  std::string encoded;
  base::buffer input(reinterpret_cast<const uint8_t*>(data),
                     reinterpret_cast<const uint8_t*>(data) + len);
  base::encode_base64(input, encoded);
  lua_pushlstring(L, encoded.data(), encoded.size());
  return 1;
}

int Base64_decode(lua_State* L)
{
  size_t len = 0;
  const char* data = luaL_checklstring(L, 1, &len);
  base::buffer decoded;
  base::decode_base64(std::string(data, len), decoded);
  lua_pushlstring(L,
                  reinterpret_cast<const char*>(decoded.data()),
                  decoded.size());
  return 1;
}

const luaL_Reg Base64_methods[] = {
  { "encode", Base64_encode },
  { "decode", Base64_decode },
  { nullptr,  nullptr      }
};

} // anonymous namespace

DEF_MTNAME(Base64);

void register_base64_class(lua_State* L)
{
  REG_CLASS(L, Base64);

  lua_newtable(L);
  lua_pushvalue(L, -1);
  luaL_getmetatable(L, get_mtname<Base64>());
  lua_setmetatable(L, -2);
  lua_setglobal(L, "base64");
}

}} // namespace app::script

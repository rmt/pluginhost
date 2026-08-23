proc abiSize*(typeId: int32): uint64 {.
  importc: "pluginhost_abi_size", cdecl, gcsafe, raises: [].}
proc abiAlign*(typeId: int32): uint64 {.
  importc: "pluginhost_abi_align", cdecl, gcsafe, raises: [].}
proc abiOffset*(fieldId: int32): uint64 {.
  importc: "pluginhost_abi_offset", cdecl, gcsafe, raises: [].}
proc abiConstant*(constantId: int32): int64 {.
  importc: "pluginhost_abi_constant", cdecl, gcsafe, raises: [].}
proc abiString*(stringId: int32): cstring {.
  importc: "pluginhost_abi_string", cdecl, gcsafe, raises: [].}
proc abiClapVersionIsCompatible*(major, minor, revision: uint32): cint {.
  importc: "pluginhost_abi_clap_version_is_compatible",
  cdecl, gcsafe, raises: [].}

func abiFieldId*(typeId, fieldId: int32): int32 =
  typeId * 100'i32 + fieldId

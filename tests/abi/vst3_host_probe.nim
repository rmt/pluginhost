import pluginhost/vst3/ffi

type
  Vst3HostProbe* = object
    iface*: Vst3FUnknown
    vtbl: Vst3FUnknownVtbl
    queryCalls*: uint32
    addRefCalls*: uint32
    releaseCalls*: uint32

proc probeQuery(thisInterface: pointer; iid: ptr Vst3Tuid;
                obj: ptr pointer): int32 {.cdecl, gcsafe, raises: [].} =
  let probe = cast[ptr Vst3HostProbe](thisInterface)
  if probe == nil:
    return Vst3InvalidArgument
  discard iid
  inc probe.queryCalls
  if obj != nil:
    obj[] = nil
  Vst3NoInterface

proc probeAddRef(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let probe = cast[ptr Vst3HostProbe](thisInterface)
  if probe == nil:
    return 0
  inc probe.addRefCalls
  probe.addRefCalls

proc probeRelease(thisInterface: pointer): uint32 {.cdecl, gcsafe, raises: [].} =
  let probe = cast[ptr Vst3HostProbe](thisInterface)
  if probe == nil:
    return 0
  inc probe.releaseCalls
  probe.releaseCalls

proc initVst3HostProbe*(probe: var Vst3HostProbe) =
  probe.queryCalls = 0
  probe.addRefCalls = 0
  probe.releaseCalls = 0
  probe.vtbl = Vst3FUnknownVtbl(
    queryInterface: probeQuery,
    addRef: probeAddRef,
    release: probeRelease,
  )
  probe.iface.lpVtbl = addr probe.vtbl

proc interfacePointer*(probe: var Vst3HostProbe): pointer =
  addr probe.iface

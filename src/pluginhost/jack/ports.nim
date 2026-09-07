## Transactional realization of immutable host PortPlan values as JACK ports.
## Managed names and registration bookkeeping stay on the control plane; RtPortMap
## is fixed-layout POD storage borrowed by callbacks only while the client is open.

import std/[sets, typetraits]

import ../domain/[errors, port_plan, result]
import ../support/utf8
import ./[api, ffi]

const
  RtMaxNotePortsPerDirection* = 1_024'u32

type
  JackPortKind* = enum
    jpkAudio
    jpkNote

  JackPortIdentity* = object
    kind*: JackPortKind
    direction*: PortDirection
    id*: uint32
    channel*: uint32

  JackOwnedPort* = object
    port*: JackPort
    identity*: JackPortIdentity
  RtPortMap* = object
    version*: uint64
    audioInputCount*: uint32
    audioOutputCount*: uint32
    noteInputCount*: uint32
    noteOutputCount*: uint32
    audioInputs*: array[4_096, JackPort]
    audioOutputs*: array[4_096, JackPort]
    noteInputs*: array[int(RtMaxNotePortsPerDirection), JackPort]
    noteOutputs*: array[int(RtMaxNotePortsPerDirection), JackPort]

  JackPortOwner* = object
    registered: seq[JackOwnedPort]

proc sameJackPortLayout*(left, right: PortPlan): bool =
  ## True when replacing the CLAP process endpoint need not replace JACK ports.
  if left.audioChannelCount != right.audioChannelCount or
      left.notePortCount != right.notePortCount:
    return false
  for index in 0 ..< left.audioChannelCount:
    let a = left.audioChannel(index)
    let b = right.audioChannel(index)
    if a.groupId != b.groupId or a.channelIndex != b.channelIndex or
        a.direction != b.direction or a.shortName != b.shortName or
        a.alias != b.alias:
      return false
  for index in 0 ..< left.notePortCount:
    let a = left.notePort(index)
    let b = right.notePort(index)
    if a.id != b.id or a.direction != b.direction or a.name != b.name or
        a.shortName != b.shortName:
      return false
  true

static:
  doAssert supportsCopyMem(RtPortMap)

proc `=destroy`*(owner: var JackPortOwner) =
  doAssert owner.registered.len == 0,
    "owned JACK ports must be released before destruction"
  `=destroy`(owner.registered)

proc `=copy`*(destination: var JackPortOwner; source: JackPortOwner) {.error:
  "JackPortOwner owns JACK ports and cannot be copied; use move".}
proc `=dup`*(source: JackPortOwner): JackPortOwner {.error:
  "JackPortOwner owns JACK ports and cannot be duplicated; use move".}

proc `=sink`*(destination: var JackPortOwner; source: JackPortOwner) =
  doAssert destination.registered.len == 0,
    "owned JACK ports must be released before move assignment"
  `=sink`(destination.registered, source.registered)

proc registeredPortCount*(owner: JackPortOwner): int {.inline.} =
  owner.registered.len

iterator ownedPorts*(owner: JackPortOwner): JackOwnedPort =
  for owned in owner.registered:
    yield owned

proc discardAfterClientClose*(owner: var JackPortOwner) =
  ## jack_client_close releases all ports owned by the client.
  owner.registered.setLen(0)

proc unregisterOwnedPorts*(owner: var JackPortOwner; functions: JackFunctions;
                           client: JackClient; clientName: string): Result[Unit] =
  var index = owner.registered.len
  var failedStatus = 0.cint
  while index > 0:
    dec index
    let status = functions.portUnregister(client, owner.registered[index].port)
    if status != 0 and failedStatus == 0:
      failedStatus = status
  owner.registered.setLen(0)
  if failedStatus != 0:
    return failure[Unit](hostError(
      hsJack, hekJackPortRegistration,
      "could not unregister realized JACK ports",
      "client=" & clientName & "; status=" & $failedStatus,
    ))
  success()

proc portError(kind: HostErrorKind; message, clientName, detail: string): HostError =
  var context = "client=" & clientName
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsJack, kind, message, context)

proc rollback(owner: var JackPortOwner; functions: JackFunctions;
              client: JackClient; clientName: string; primary: HostError;
              rollbackComplete: var bool): HostError =
  var index = owner.registered.len
  var failedStatus = 0.cint
  while index > 0:
    dec index
    let status = functions.portUnregister(client, owner.registered[index].port)
    if status != 0 and failedStatus == 0:
      failedStatus = status
  owner.registered.setLen(0)
  rollbackComplete = failedStatus == 0

  if rollbackComplete:
    return primary
  result = portError(
    hekJackPortRegistration,
    "could not roll back partially registered JACK ports",
    clientName,
    "status=" & $failedStatus & "; primary=" & primary.message &
      " (" & primary.context & ")",
  )

proc hasEmbeddedNul(value: string): bool {.inline.} =
  value.find('\0') >= 0

proc validateShortName(clientName, shortName: string; portNameSize: int;
                       ordinal: int): Result[Unit] =
  if shortName.len == 0 or shortName.hasEmbeddedNul:
    return failure[Unit](portError(
      hekJackPortName,
      "JACK port short name is invalid",
      clientName,
      "count=" & $ordinal & "; name=" & shortName,
    ))
  let fullBytesWithNul = clientName.len + 1 + shortName.len + 1
  if portNameSize <= 0 or fullBytesWithNul > portNameSize:
    return failure[Unit](portError(
      hekJackPortName,
      "JACK port name exceeds the server limit",
      clientName,
      "count=" & $ordinal & "; name=" & shortName &
        "; required=" & $fullBytesWithNul & "; limit=" & $portNameSize,
    ))
  success()

proc boundedAlias(clientName, metadataName: string;
                  portNameSize: int): Result[string] =
  if metadataName.len == 0:
    return success("")
  if metadataName.hasEmbeddedNul:
    return failure[string](portError(
      hekJackPortAlias,
      "JACK port alias is invalid",
      clientName,
      "alias contains a null byte",
    ))

  let prefix = clientName & ":"
  let maximumAliasBytes = portNameSize - 1
  let availableMetadataBytes = maximumAliasBytes - prefix.len
  if availableMetadataBytes <= 0:
    return failure[string](portError(
      hekJackPortAlias,
      "JACK port alias cannot fit the server limit",
      clientName,
      "limit=" & $portNameSize,
    ))
  let truncated = metadataName.truncateUtf8Bytes(availableMetadataBytes)
  if truncated.len == 0:
    return failure[string](portError(
      hekJackPortAlias,
      "JACK port alias cannot fit one complete UTF-8 code point",
      clientName,
      "limit=" & $portNameSize,
    ))
  success(prefix & truncated)

proc addAudioPort(map: var RtPortMap; direction: PortDirection;
                  port: JackPort): bool =
  case direction
  of pdInput:
    if map.audioInputCount >= 4_096'u32:
      return false
    map.audioInputs[int(map.audioInputCount)] = port
    inc map.audioInputCount
  of pdOutput:
    if map.audioOutputCount >= 4_096'u32:
      return false
    map.audioOutputs[int(map.audioOutputCount)] = port
    inc map.audioOutputCount
  true

proc addNotePort(map: var RtPortMap; direction: PortDirection;
                 port: JackPort): bool =
  case direction
  of pdInput:
    if map.noteInputCount >= RtMaxNotePortsPerDirection:
      return false
    map.noteInputs[int(map.noteInputCount)] = port
    inc map.noteInputCount
  of pdOutput:
    if map.noteOutputCount >= RtMaxNotePortsPerDirection:
      return false
    map.noteOutputs[int(map.noteOutputCount)] = port
    inc map.noteOutputCount
  true

proc registerOne(functions: JackFunctions; client: JackClient;
                 clientName, shortName, alias, portType: string;
                 direction: PortDirection; identity: JackPortIdentity; ordinal: int;
                 portNameSize: int; owner: var JackPortOwner): Result[JackPort] =
  let validName = validateShortName(clientName, shortName, portNameSize, ordinal)
  if not validName.isOk:
    return failure[JackPort](validName.error)

  let flags = case direction
    of pdInput: JackPortIsInput
    of pdOutput: JackPortIsOutput
  let port = functions.portRegister(
    client, shortName.cstring, portType.cstring, flags, 0.culong)
  if port == nil:
    return failure[JackPort](portError(
      hekJackPortRegistration,
      "could not register required JACK port",
      clientName,
      "count=" & $ordinal & "; name=" & shortName & "; type=" & portType,
    ))
  owner.registered.add(JackOwnedPort(port: port, identity: identity))

  let realizedAlias = boundedAlias(clientName, alias, portNameSize)
  if not realizedAlias.isOk:
    return failure[JackPort](realizedAlias.error)
  if realizedAlias.value.len > 0 and
      functions.portSetAlias(port, realizedAlias.value.cstring) != 0:
    return failure[JackPort](portError(
      hekJackPortAlias,
      "could not set required JACK port alias",
      clientName,
      "count=" & $ordinal & "; name=" & shortName &
        "; alias=" & realizedAlias.value,
    ))
  success(port)

proc realizePortPlan*(functions: JackFunctions; client: JackClient;
                      clientName: string; portNameSize: int; plan: PortPlan;
                      map: var RtPortMap; owner: var JackPortOwner;
                      rollbackComplete: var bool): Result[Unit] =
  ## Builds a complete candidate map before publishing it to callback storage.
  doAssert owner.registered.len == 0
  rollbackComplete = true
  if client == nil:
    return failure[Unit](portError(
      hekJackPortRegistration,
      "cannot register JACK ports without an open client",
      clientName,
      "client handle is null",
    ))

  var candidateMap = RtPortMap(version: plan.version.value)
  var candidateOwner: JackPortOwner
  var names = initHashSet[string]()
  var ordinal = 0

  for channel in plan.audioChannels:
    inc ordinal
    if channel.shortName in names:
      let primary = portError(
        hekJackPortName,
        "JACK port short names must be unique",
        clientName,
        "count=" & $ordinal & "; name=" & channel.shortName,
      )
      return failure[Unit](candidateOwner.rollback(
        functions, client, clientName, primary, rollbackComplete))
    names.incl(channel.shortName)

    let registered = registerOne(
      functions, client, clientName, channel.shortName, channel.alias,
      JackDefaultAudioType, channel.direction, JackPortIdentity(
      kind: jpkAudio, direction: channel.direction, id: channel.groupId,
      channel: channel.channelIndex), ordinal, portNameSize,
      candidateOwner)
    if not registered.isOk:
      return failure[Unit](candidateOwner.rollback(
        functions, client, clientName, registered.error, rollbackComplete))
    if not candidateMap.addAudioPort(channel.direction, registered.value):
      let primary = portError(
        hekJackPortRegistration,
        "JACK audio port count exceeds the real-time map capacity",
        clientName,
        "count=" & $ordinal,
      )
      return failure[Unit](candidateOwner.rollback(
        functions, client, clientName, primary, rollbackComplete))

  for note in plan.notePorts:
    inc ordinal
    if note.shortName in names:
      let primary = portError(
        hekJackPortName,
        "JACK port short names must be unique",
        clientName,
        "count=" & $ordinal & "; name=" & note.shortName,
      )
      return failure[Unit](candidateOwner.rollback(
        functions, client, clientName, primary, rollbackComplete))
    names.incl(note.shortName)

    let registered = registerOne(
      functions, client, clientName, note.shortName, note.name,
      JackDefaultMidiType, note.direction, JackPortIdentity(
      kind: jpkNote, direction: note.direction, id: note.id, channel: 0'u32),
      ordinal, portNameSize,
      candidateOwner)
    if not registered.isOk:
      return failure[Unit](candidateOwner.rollback(
        functions, client, clientName, registered.error, rollbackComplete))
    if not candidateMap.addNotePort(note.direction, registered.value):
      let primary = portError(
        hekJackPortRegistration,
        "JACK note port count exceeds the real-time map capacity",
        clientName,
        "count=" & $ordinal,
      )
      return failure[Unit](candidateOwner.rollback(
        functions, client, clientName, primary, rollbackComplete))

  map = candidateMap
  owner = move(candidateOwner)
  success()

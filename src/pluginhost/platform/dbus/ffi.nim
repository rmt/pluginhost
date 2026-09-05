## Minimal declaration-only libdbus-1 ABI used by the StatusNotifierItem host.
##
## The library is loaded explicitly by api.nim. D-Bus callbacks are invoked only
## while the main thread dispatches its registered connection descriptor.

when not defined(linux):
  {.error: "pluginhost/platform/dbus is available only on Linux".}

const
  DbusLibrary* = "libdbus-1.so.3"

  DbusTypeInvalid* = 0.cint
  DbusTypeByte* = ord('y').cint
  DbusTypeBoolean* = ord('b').cint
  DbusTypeInt32* = ord('i').cint
  DbusTypeUint32* = ord('u').cint
  DbusTypeString* = ord('s').cint
  DbusTypeObjectPath* = ord('o').cint
  DbusTypeSignature* = ord('g').cint
  DbusTypeArray* = ord('a').cint
  DbusTypeVariant* = ord('v').cint
  DbusTypeStruct* = ord('r').cint
  DbusTypeDictEntry* = ord('e').cint

  DbusBusSession* = 0.cint
  DbusNameFlagDoNotQueue* = 0x4.cuint
  DbusRequestNameReplyPrimaryOwner* = 1.cint
  DbusRequestNameReplyAlreadyOwner* = 4.cint

  DbusMessageTypeMethodCall* = 1.cint
  DbusMessageTypeMethodReturn* = 2.cint
  DbusMessageTypeError* = 3.cint
  DbusMessageTypeSignal* = 4.cint

  DbusHandlerResultHandled* = 0.cint
  DbusHandlerResultNotYetHandled* = 1.cint

  DbusWatchReadable* = 1.cuint
  DbusWatchWritable* = 2.cuint
  DbusWatchError* = 4.cuint
  DbusWatchHangup* = 8.cuint

type
  DBusConnection* = object
  DBusMessage* = object
  DBusWatch* = object

  DBusError* {.bycopy.} = object
    name*: cstring
    message*: cstring
    dummyFlags*: cuint
    padding*: pointer

  ## This is a public stack-allocated opaque structure in dbus-message.h.
  DBusMessageIter* {.bycopy.} = object
    dummy1*: pointer
    dummy2*: pointer
    dummy3*: uint32
    dummy4*: cint
    dummy5*: cint
    dummy6*: cint
    dummy7*: cint
    dummy8*: cint
    dummy9*: cint
    dummy10*: cint
    dummy11*: cint
    pad1*: cint
    pad2*: pointer
    pad3*: pointer

  DBusBusGetPrivateProc* = proc(busType: cint; error: ptr DBusError): ptr DBusConnection {.
    cdecl, gcsafe, raises: [].}
  DBusThreadsInitDefaultProc* = proc(): cuint {.cdecl, gcsafe, raises: [].}
  DBusBusRequestNameProc* = proc(connection: ptr DBusConnection; name: cstring;
      flags: cuint; error: ptr DBusError): cint {.cdecl, gcsafe, raises: [].}
  DBusBusReleaseNameProc* = proc(connection: ptr DBusConnection; name: cstring;
      error: ptr DBusError): cint {.cdecl, gcsafe, raises: [].}

  DBusConnectionSetExitOnDisconnectProc* = proc(
      connection: ptr DBusConnection; exitOnDisconnect: cuint) {.
    cdecl, gcsafe, raises: [].}
  DBusConnectionGetIsConnectedProc* = proc(
      connection: ptr DBusConnection): cuint {.cdecl, gcsafe, raises: [].}
  DBusConnectionGetUnixFdProc* = proc(connection: ptr DBusConnection;
      fd: ptr cint): cuint {.cdecl, gcsafe, raises: [].}
  DBusConnectionReadWriteDispatchProc* = proc(connection: ptr DBusConnection;
      timeoutMilliseconds: cint): cuint {.cdecl, gcsafe, raises: [].}
  DBusConnectionCloseProc* = proc(connection: ptr DBusConnection) {.
    cdecl, gcsafe, raises: [].}
  DBusConnectionUnrefProc* = proc(connection: ptr DBusConnection) {.
    cdecl, gcsafe, raises: [].}
  DBusConnectionSendWithReplyAndBlockProc* = proc(
      connection: ptr DBusConnection; message: ptr DBusMessage;
      timeoutMilliseconds: cint; error: ptr DBusError): ptr DBusMessage {.
    cdecl, gcsafe, raises: [].}
  DBusConnectionSendProc* = proc(connection: ptr DBusConnection;
      message: ptr DBusMessage; clientSerial: ptr uint32): cuint {.
    cdecl, gcsafe, raises: [].}
  DBusConnectionFlushProc* = proc(connection: ptr DBusConnection) {.
    cdecl, gcsafe, raises: [].}

  DBusObjectPathUnregisterProc* = proc(connection: ptr DBusConnection;
      userData: pointer) {.cdecl, gcsafe, raises: [].}
  DBusObjectPathMessageProc* = proc(connection: ptr DBusConnection;
      message: ptr DBusMessage; userData: pointer): cint {.
    cdecl, gcsafe, raises: [].}
  DBusObjectPathPadProc* = proc(data: pointer) {.cdecl, gcsafe, raises: [].}

  DBusObjectPathVTable* {.bycopy.} = object
    unregisterFunction*: DBusObjectPathUnregisterProc
    messageFunction*: DBusObjectPathMessageProc
    pad1*: DBusObjectPathPadProc
    pad2*: DBusObjectPathPadProc
    pad3*: DBusObjectPathPadProc
    pad4*: DBusObjectPathPadProc

  DBusConnectionRegisterObjectPathProc* = proc(connection: ptr DBusConnection;
      path: cstring; vtable: ptr DBusObjectPathVTable; userData: pointer): cuint {.
    cdecl, gcsafe, raises: [].}
  DBusConnectionUnregisterObjectPathProc* = proc(connection: ptr DBusConnection;
      path: cstring): cuint {.cdecl, gcsafe, raises: [].}

  DBusMessageNewMethodCallProc* = proc(busName, path, iface, methodName: cstring):
      ptr DBusMessage {.cdecl, gcsafe, raises: [].}
  DBusMessageNewMethodReturnProc* = proc(methodCall: ptr DBusMessage):
      ptr DBusMessage {.cdecl, gcsafe, raises: [].}
  DBusMessageNewErrorProc* = proc(replyTo: ptr DBusMessage; errorName,
      errorMessage: cstring): ptr DBusMessage {.cdecl, gcsafe, raises: [].}
  DBusMessageUnrefProc* = proc(message: ptr DBusMessage) {.
    cdecl, gcsafe, raises: [].}
  DBusMessageGetInterfaceProc* = proc(message: ptr DBusMessage): cstring {.
    cdecl, gcsafe, raises: [].}
  DBusMessageGetMemberProc* = proc(message: ptr DBusMessage): cstring {.
    cdecl, gcsafe, raises: [].}
  DBusMessageGetTypeProc* = proc(message: ptr DBusMessage): cint {.
    cdecl, gcsafe, raises: [].}
  DBusMessageIsMethodCallProc* = proc(message: ptr DBusMessage; iface,
      methodName: cstring): cuint {.cdecl, gcsafe, raises: [].}

  DBusErrorInitProc* = proc(error: ptr DBusError) {.cdecl, gcsafe, raises: [].}
  DBusErrorFreeProc* = proc(error: ptr DBusError) {.cdecl, gcsafe, raises: [].}
  DBusErrorIsSetProc* = proc(error: ptr DBusError): cuint {.cdecl, gcsafe, raises: [].}

  DBusMessageIterInitProc* = proc(message: ptr DBusMessage;
      iter: ptr DBusMessageIter): cuint {.cdecl, gcsafe, raises: [].}
  DBusMessageIterInitAppendProc* = proc(message: ptr DBusMessage;
      iter: ptr DBusMessageIter) {.cdecl, gcsafe, raises: [].}
  DBusMessageIterHasNextProc* = proc(iter: ptr DBusMessageIter): cuint {.
    cdecl, gcsafe, raises: [].}
  DBusMessageIterNextProc* = proc(iter: ptr DBusMessageIter): cuint {.
    cdecl, gcsafe, raises: [].}
  DBusMessageIterGetArgTypeProc* = proc(iter: ptr DBusMessageIter): cint {.
    cdecl, gcsafe, raises: [].}
  DBusMessageIterGetBasicProc* = proc(iter: ptr DBusMessageIter;
      value: pointer) {.cdecl, gcsafe, raises: [].}
  DBusMessageIterAppendBasicProc* = proc(iter: ptr DBusMessageIter;
      argType: cint; value: pointer): cuint {.cdecl, gcsafe, raises: [].}
  DBusMessageIterOpenContainerProc* = proc(iter: ptr DBusMessageIter;
      containerType: cint; containedSignature: cstring;
      sub: ptr DBusMessageIter): cuint {.cdecl, gcsafe, raises: [].}
  DBusMessageIterCloseContainerProc* = proc(iter, sub: ptr DBusMessageIter): cuint {.
    cdecl, gcsafe, raises: [].}
  DBusMessageIterAbandonContainerProc* = proc(iter, sub: ptr DBusMessageIter) {.
    cdecl, gcsafe, raises: [].}
  DBusMessageIterAppendFixedArrayProc* = proc(iter: ptr DBusMessageIter;
      elementType: cint; value: pointer; elementCount: cint): cuint {.
    cdecl, gcsafe, raises: [].}
  DBusMessageIterRecurseProc* = proc(iter: ptr DBusMessageIter;
      sub: ptr DBusMessageIter) {.cdecl, gcsafe, raises: [].}

  DbusFunctions* = object
    busGetPrivate*: DBusBusGetPrivateProc
    threadsInitDefault*: DBusThreadsInitDefaultProc
    busRequestName*: DBusBusRequestNameProc
    busReleaseName*: DBusBusReleaseNameProc
    connectionSetExitOnDisconnect*: DBusConnectionSetExitOnDisconnectProc
    connectionGetIsConnected*: DBusConnectionGetIsConnectedProc
    connectionGetUnixFd*: DBusConnectionGetUnixFdProc
    connectionReadWriteDispatch*: DBusConnectionReadWriteDispatchProc
    connectionClose*: DBusConnectionCloseProc
    connectionUnref*: DBusConnectionUnrefProc
    connectionSendWithReplyAndBlock*: DBusConnectionSendWithReplyAndBlockProc
    connectionSend*: DBusConnectionSendProc
    connectionFlush*: DBusConnectionFlushProc
    connectionRegisterObjectPath*: DBusConnectionRegisterObjectPathProc
    connectionUnregisterObjectPath*: DBusConnectionUnregisterObjectPathProc
    messageNewMethodCall*: DBusMessageNewMethodCallProc
    messageNewMethodReturn*: DBusMessageNewMethodReturnProc
    messageNewError*: DBusMessageNewErrorProc
    messageUnref*: DBusMessageUnrefProc
    messageGetInterface*: DBusMessageGetInterfaceProc
    messageGetMember*: DBusMessageGetMemberProc
    messageGetType*: DBusMessageGetTypeProc
    messageIsMethodCall*: DBusMessageIsMethodCallProc
    errorInit*: DBusErrorInitProc
    errorFree*: DBusErrorFreeProc
    errorIsSet*: DBusErrorIsSetProc
    messageIterInit*: DBusMessageIterInitProc
    messageIterInitAppend*: DBusMessageIterInitAppendProc
    messageIterHasNext*: DBusMessageIterHasNextProc
    messageIterNext*: DBusMessageIterNextProc
    messageIterGetArgType*: DBusMessageIterGetArgTypeProc
    messageIterGetBasic*: DBusMessageIterGetBasicProc
    messageIterAppendBasic*: DBusMessageIterAppendBasicProc
    messageIterOpenContainer*: DBusMessageIterOpenContainerProc
    messageIterCloseContainer*: DBusMessageIterCloseContainerProc
    messageIterAbandonContainer*: DBusMessageIterAbandonContainerProc
    messageIterAppendFixedArray*: DBusMessageIterAppendFixedArrayProc
    messageIterRecurse*: DBusMessageIterRecurseProc


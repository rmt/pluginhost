## StatusNotifierItem tray icon over the session bus.
##
## The backend owns one private libdbus connection and exports only bounded
## activation events through the backend-neutral tray seam. The connection is
## dispatched by the CLAP/main reactor, never by the JACK process thread.

import std/[posix, strutils]

import ../../domain/[errors, result]
import ../../gui/[icon, tray_icon]
import ./[api, ffi]

const
  SniServicePrefix = "org.freedesktop.StatusNotifierItem-"
  SniObjectPath = "/StatusNotifierItem"
  SniInterface = "org.freedesktop.StatusNotifierItem"
  SniKdeInterface = "org.kde.StatusNotifierItem"
  PropertiesInterface = "org.freedesktop.DBus.Properties"
  IntrospectableInterface = "org.freedesktop.DBus.Introspectable"
  WatcherService = "org.freedesktop.StatusNotifierWatcher"
  WatcherKdeService = "org.kde.StatusNotifierWatcher"
  WatcherPath = "/StatusNotifierWatcher"
  WatcherInterface = "org.freedesktop.StatusNotifierWatcher"
  WatcherKdeInterface = "org.kde.StatusNotifierWatcher"
  RegistrationTimeoutMilliseconds = 1_000.cint
  MaxDbusDispatchPerPoll = 128
  MaxPixmapBytes = int(MaxIconPixels * 4'u32)

const
  IntrospectionXml = """
<node>
  <interface name='org.freedesktop.StatusNotifierItem'>
    <method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
    <method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
    <method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
    <method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>
    <property name='Category' type='s' access='read'/>
    <property name='Id' type='s' access='read'/>
    <property name='Title' type='s' access='read'/>
    <property name='Status' type='s' access='read'/>
    <property name='WindowId' type='u' access='read'/>
    <property name='IconName' type='s' access='read'/>
    <property name='IconPixmap' type='a(iiay)' access='read'/>
    <property name='OverlayIconName' type='s' access='read'/>
    <property name='OverlayIconPixmap' type='a(iiay)' access='read'/>
    <property name='AttentionIconName' type='s' access='read'/>
    <property name='AttentionIconPixmap' type='a(iiay)' access='read'/>
    <property name='AttentionMovieName' type='s' access='read'/>
    <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>
    <property name='ItemIsMenu' type='b' access='read'/>
    <property name='Menu' type='o' access='read'/>
  </interface>
  <interface name='org.kde.StatusNotifierItem'>
    <method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
    <method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
    <method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
    <method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>
    <property name='Category' type='s' access='read'/>
    <property name='Id' type='s' access='read'/>
    <property name='Title' type='s' access='read'/>
    <property name='Status' type='s' access='read'/>
    <property name='WindowId' type='u' access='read'/>
    <property name='ItemIsMenu' type='b' access='read'/>
    <property name='IconPixmap' type='a(iiay)' access='read'/>
  </interface>
  <interface name='org.freedesktop.DBus.Properties'>
    <method name='Get'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>
    <method name='GetAll'><arg type='s' direction='in'/><arg type='a{sv}' direction='out'/></method>
  </interface>
  <interface name='org.freedesktop.DBus.Introspectable'>
    <method name='Introspect'><arg type='s' direction='out'/></method>
  </interface>
</node>
"""


type
  DbusTrayIconOwner = object
    api: DbusApi
    connection: ptr DBusConnection
    serviceName: string
    title: string
    icon: GuiIcon
    connectionFd: int32
    nameOwned: bool
    pathRegistered: bool
    activationPending: bool

  DbusTrayIcon* = ref object of TrayIconBackend
    owner: DbusTrayIconOwner

proc dbusTrayMessage(connection: ptr DBusConnection; message: ptr DBusMessage;
                     userData: pointer): cint {.cdecl, gcsafe, raises: [].}

var DbusTrayVTable = DBusObjectPathVTable(
  unregisterFunction: nil,
  messageFunction: dbusTrayMessage,
  pad1: nil,
  pad2: nil,
  pad3: nil,
  pad4: nil,
)

proc dbusTrayError(message: string; context = ""): HostError =
  hostError(hsGui, hekGui, message, context)

proc cstringEquals(value: cstring; expected: static[string]): bool {.inline.} =
  if value == nil:
    return false
  let bytes = cast[ptr UncheckedArray[char]](value)
  for index in 0 ..< expected.len:
    if bytes[index] == '\0' or bytes[index] != expected[index]:
      return false
  bytes[expected.len] == '\0'

proc errorDetail(functions: ptr DbusFunctions; error: DBusError): string =
  if error.name != nil:
    result = $error.name
  if error.message != nil:
    if result.len > 0:
      result.add(": ")
    result.add($error.message)
  if result.len == 0:
    result = "no D-Bus error detail"
  discard functions

proc appendBasic(functions: ptr DbusFunctions; iter: ptr DBusMessageIter;
                argType: cint; value: pointer): bool {.inline.} =
  functions[].messageIterAppendBasic(iter, argType, value) != 0'u32

proc appendString(functions: ptr DbusFunctions; iter: ptr DBusMessageIter;
                 value: string; argType = DbusTypeString): bool =
  var text = value.cstring
  appendBasic(functions, iter, argType, addr text)

proc appendUint32(functions: ptr DbusFunctions; iter: ptr DBusMessageIter;
                  value: uint32): bool =
  var number = value
  appendBasic(functions, iter, DbusTypeUint32, addr number)

proc appendBool(functions: ptr DbusFunctions; iter: ptr DBusMessageIter;
               value: bool): bool =
  var encoded = if value: 1'u32 else: 0'u32
  appendBasic(functions, iter, DbusTypeBoolean, addr encoded)

proc appendInt32(functions: ptr DbusFunctions; iter: ptr DBusMessageIter;
                 value: int32): bool =
  var number = value
  appendBasic(functions, iter, DbusTypeInt32, addr number)

proc appendContainer(functions: ptr DbusFunctions; parent: ptr DBusMessageIter;
                     containerType: cint; signature: cstring;
                     child: ptr DBusMessageIter): bool {.inline.} =
  functions[].messageIterOpenContainer(parent, containerType, signature, child) != 0'u32

proc closeContainer(functions: ptr DbusFunctions; parent, child: ptr DBusMessageIter): bool {.inline.} =
  functions[].messageIterCloseContainer(parent, child) != 0'u32

proc abandonContainer(functions: ptr DbusFunctions; parent, child: ptr DBusMessageIter) {.inline.} =
  functions[].messageIterAbandonContainer(parent, child)

proc pixmapBytes(icon: GuiIcon): seq[uint8] =
  if icon == nil or icon.pixels.len == 0 or icon.pixels.len * 4 > MaxPixmapBytes:
    return @[]
  result = newSeq[uint8](icon.pixels.len * 4)
  for index, pixel in icon.pixels:
    # The SNI specification transports ARGB32 in network byte order, even
    # though X11's _NET_WM_ICON property uses native long elements.
    result[index * 4] = uint8((pixel shr 24) and 0xff'u32)
    result[index * 4 + 1] = uint8((pixel shr 16) and 0xff'u32)
    result[index * 4 + 2] = uint8((pixel shr 8) and 0xff'u32)
    result[index * 4 + 3] = uint8(pixel and 0xff'u32)


proc appendPixmapStruct(functions: ptr DbusFunctions;
                        parent: ptr DBusMessageIter; icon: GuiIcon): bool =
  let bytes = pixmapBytes(icon)
  if bytes.len == 0:
    return false
  var image: DBusMessageIter
  if not appendContainer(functions, parent, DbusTypeStruct, nil, addr image):
    return false
  if not appendInt32(functions, addr image, int32(icon.width)) or
      not appendInt32(functions, addr image, int32(icon.height)):
    abandonContainer(functions, parent, addr image)
    return false
  var byteArray: DBusMessageIter
  if not appendContainer(functions, addr image, DbusTypeArray, "y", addr byteArray):
    abandonContainer(functions, parent, addr image)
    return false
  # libdbus expects the address of a pointer to the fixed-array data.
  var data = unsafeAddr bytes[0]
  let bytesOk = functions[].messageIterAppendFixedArray(
    addr byteArray, DbusTypeByte, addr data, cint(bytes.len)) != 0'u32
  if not bytesOk:
    abandonContainer(functions, addr image, addr byteArray)
    abandonContainer(functions, parent, addr image)
    return false
  if not closeContainer(functions, addr image, addr byteArray):
    abandonContainer(functions, parent, addr image)
    return false
  if not closeContainer(functions, parent, addr image):
    return false
  true
proc appendPixmap(functions: ptr DbusFunctions; parent: ptr DBusMessageIter;
                  icon: GuiIcon): bool =
  var images: DBusMessageIter
  if not appendContainer(functions, parent, DbusTypeArray, "(iiay)", addr images):
    return false
  if not appendPixmapStruct(functions, addr images, icon):
    abandonContainer(functions, parent, addr images)
    return false
  if not closeContainer(functions, parent, addr images):
    return false
  true


proc appendPropertyValue(functions: ptr DbusFunctions; iter: ptr DBusMessageIter;
                         propertyName: string; owner: var DbusTrayIconOwner): bool =
  if propertyName == "Category":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "s", addr variant):
      return false
    let ok = appendString(functions, addr variant, "ApplicationStatus")
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "Id":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "s", addr variant):
      return false
    let ok = appendString(functions, addr variant, owner.serviceName)
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "Title":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "s", addr variant):
      return false
    let ok = appendString(functions, addr variant, owner.title)
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "Status":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "s", addr variant):
      return false
    let ok = appendString(functions, addr variant, "Active")
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "IconName" or propertyName == "OverlayIconName" or
      propertyName == "AttentionIconName" or propertyName == "AttentionMovieName":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "s", addr variant):
      return false
    let ok = appendString(functions, addr variant, "")
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "IconPixmap" or propertyName == "OverlayIconPixmap" or
      propertyName == "AttentionIconPixmap":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "a(iiay)", addr variant):
      return false
    let ok = appendPixmap(functions, addr variant, owner.icon)
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "WindowId":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "u", addr variant):
      return false
    let ok = appendUint32(functions, addr variant, 0'u32)
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "ItemIsMenu":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "b", addr variant):
      return false
    let ok = appendBool(functions, addr variant, false)
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "Menu":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "o", addr variant):
      return false
    let ok = appendString(functions, addr variant, "/", DbusTypeObjectPath)
    if not ok:
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  elif propertyName == "ToolTip":
    var variant: DBusMessageIter
    if not appendContainer(functions, iter, DbusTypeVariant, "(sa(iiay)ss)", addr variant):
      return false
    var tooltip: DBusMessageIter
    if not appendContainer(functions, addr variant, DbusTypeStruct, nil, addr tooltip):
      abandonContainer(functions, iter, addr variant)
      return false
    let textOk = appendString(functions, addr tooltip, "")
    let tooltipPixmap = textOk and appendPixmap(functions, addr tooltip, owner.icon)
    let restOk = tooltipPixmap and appendString(functions, addr tooltip, owner.title) and
      appendString(functions, addr tooltip, "")
    if not restOk or not closeContainer(functions, addr variant, addr tooltip):
      abandonContainer(functions, addr variant, addr tooltip)
      abandonContainer(functions, iter, addr variant)
      return false
    if not closeContainer(functions, iter, addr variant):
      return false
  else:
    return false
  true

proc knownProperty(propertyName: cstring; kdeInterface = false): bool =
  if kdeInterface:
    return cstringEquals(propertyName, "Category") or
      cstringEquals(propertyName, "Id") or
      cstringEquals(propertyName, "Title") or
      cstringEquals(propertyName, "Status") or
      cstringEquals(propertyName, "WindowId") or
      cstringEquals(propertyName, "ItemIsMenu") or
      cstringEquals(propertyName, "IconPixmap")
  cstringEquals(propertyName, "Category") or cstringEquals(propertyName, "Id") or
    cstringEquals(propertyName, "Title") or cstringEquals(propertyName, "Status") or
    cstringEquals(propertyName, "WindowId") or cstringEquals(propertyName, "IconName") or
    cstringEquals(propertyName, "IconPixmap") or
    cstringEquals(propertyName, "OverlayIconName") or
    cstringEquals(propertyName, "OverlayIconPixmap") or
    cstringEquals(propertyName, "AttentionIconName") or
    cstringEquals(propertyName, "AttentionIconPixmap") or
    cstringEquals(propertyName, "AttentionMovieName") or
    cstringEquals(propertyName, "ToolTip") or cstringEquals(propertyName, "ItemIsMenu") or
    cstringEquals(propertyName, "Menu")

proc sendMessage(owner: var DbusTrayIconOwner; message: ptr DBusMessage) {.inline.} =
  if message == nil or owner.connection == nil:
    return
  discard owner.api.functions.connectionSend(owner.connection, message, nil)
  owner.api.functions.connectionFlush(owner.connection)
  owner.api.functions.messageUnref(message)

proc sendError(owner: var DbusTrayIconOwner; request: ptr DBusMessage;
               errorName, messageText: string) {.inline.} =
  let reply = owner.api.functions.messageNewError(
    request, errorName.cstring, messageText.cstring)
  owner.sendMessage(reply)

proc sendEmptyReply(owner: var DbusTrayIconOwner; request: ptr DBusMessage) {.inline.} =
  let reply = owner.api.functions.messageNewMethodReturn(request)
  owner.sendMessage(reply)

proc readStringArgument(functions: ptr DbusFunctions; message: ptr DBusMessage;
                        value: var cstring): bool =
  var iter: DBusMessageIter
  if functions[].messageIterInit(message, addr iter) == 0'u32 or
      functions[].messageIterGetArgType(addr iter) != DbusTypeString:
    return false
  functions[].messageIterGetBasic(addr iter, addr value)
  value != nil

proc handlePropertiesGet(owner: var DbusTrayIconOwner; message: ptr DBusMessage) {.raises: [].} =
  var iter: DBusMessageIter
  if owner.api.functions.messageIterInit(message, addr iter) == 0'u32:
    owner.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "expected interface and property")
    return
  if owner.api.functions.messageIterGetArgType(addr iter) != DbusTypeString:
    owner.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "expected interface and property")
    return
  var interfaceName: cstring
  owner.api.functions.messageIterGetBasic(addr iter, addr interfaceName)
  if owner.api.functions.messageIterNext(addr iter) == 0'u32 or
      owner.api.functions.messageIterGetArgType(addr iter) != DbusTypeString:
    owner.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "expected interface and property")
    return
  var propertyName: cstring
  owner.api.functions.messageIterGetBasic(addr iter, addr propertyName)
  let kdeInterface = cstringEquals(interfaceName, SniKdeInterface)
  if (not cstringEquals(interfaceName, SniInterface) and not kdeInterface) or
      not knownProperty(propertyName, kdeInterface):
    owner.sendError(message, "org.freedesktop.DBus.Error.UnknownProperty", "unknown StatusNotifierItem property")
    return
  let reply = owner.api.functions.messageNewMethodReturn(message)
  if reply == nil:
    return
  var output: DBusMessageIter
  owner.api.functions.messageIterInitAppend(reply, addr output)
  if not appendPropertyValue(addr owner.api.functions, addr output, $propertyName,
      owner):
    owner.api.functions.messageUnref(reply)
    return
  owner.sendMessage(reply)

type
  PropertyNameList = array[15, string]
  KdePropertyNameList = array[7, string]

proc propertySignature(propertyName: string): cstring =
  if propertyName == "WindowId":
    "u".cstring
  elif propertyName == "ItemIsMenu":
    "b".cstring
  elif propertyName in ["IconPixmap", "OverlayIconPixmap", "AttentionIconPixmap"]:
    "a(iiay)".cstring
  elif propertyName == "ToolTip":
    "(sa(iiay)ss)".cstring
  elif propertyName == "Menu":
    "o".cstring
  else:
    "s".cstring

const AllPropertyNames: PropertyNameList = [
  "Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap",
  "OverlayIconName", "OverlayIconPixmap", "AttentionIconName",
  "AttentionIconPixmap", "AttentionMovieName", "ToolTip", "ItemIsMenu", "Menu"]

const KdePropertyNames: KdePropertyNameList = [
  "Category", "Id", "Title", "Status", "WindowId", "ItemIsMenu", "IconPixmap"]
proc handlePropertiesGetAll(owner: var DbusTrayIconOwner; message: ptr DBusMessage) {.raises: [].} =
  var interfaceName: cstring
  if not readStringArgument(addr owner.api.functions, message, interfaceName):
    owner.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "expected StatusNotifierItem interface")
    return
  let kdeInterface = cstringEquals(interfaceName, SniKdeInterface)
  if not cstringEquals(interfaceName, SniInterface) and not kdeInterface:
    owner.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "expected StatusNotifierItem interface")
    return
  let reply = owner.api.functions.messageNewMethodReturn(message)
  if reply == nil:
    return
  var output: DBusMessageIter
  owner.api.functions.messageIterInitAppend(reply, addr output)
  var properties: DBusMessageIter
  if not appendContainer(addr owner.api.functions, addr output, DbusTypeArray, "{sv}", addr properties):
    owner.api.functions.messageUnref(reply)
    return
  for propertyName in AllPropertyNames:
    if kdeInterface and propertyName notin KdePropertyNames:
      continue
    var entry: DBusMessageIter
    if not appendContainer(addr owner.api.functions, addr properties,
        DbusTypeDictEntry, nil, addr entry):
      abandonContainer(addr owner.api.functions, addr output, addr properties)
      owner.api.functions.messageUnref(reply)
      return
    let appended = appendString(addr owner.api.functions, addr entry, propertyName)
    var variant: DBusMessageIter
    let opened = appended and appendContainer(
      addr owner.api.functions, addr entry, DbusTypeVariant,
      propertySignature(propertyName), addr variant)
    var valueOk = false
    if opened:
      if propertyName == "Category":
        valueOk = appendString(addr owner.api.functions, addr variant, "ApplicationStatus")
      elif propertyName == "Id":
        valueOk = appendString(addr owner.api.functions, addr variant, owner.serviceName)
      elif propertyName == "Title":
        valueOk = appendString(addr owner.api.functions, addr variant, owner.title)
      elif propertyName == "Status":
        valueOk = appendString(addr owner.api.functions, addr variant, "Active")
      elif propertyName in ["IconName", "OverlayIconName", "AttentionIconName", "AttentionMovieName"]:
        valueOk = appendString(addr owner.api.functions, addr variant, "")
      elif propertyName in ["IconPixmap", "OverlayIconPixmap", "AttentionIconPixmap"]:
        valueOk = appendPixmap(addr owner.api.functions, addr variant, owner.icon)
      elif propertyName == "WindowId":
        valueOk = appendUint32(addr owner.api.functions, addr variant, 0'u32)
      elif propertyName == "ItemIsMenu":
        valueOk = appendBool(addr owner.api.functions, addr variant, false)
      elif propertyName == "Menu":
        valueOk = appendString(addr owner.api.functions, addr variant, "/", DbusTypeObjectPath)
      elif propertyName == "ToolTip":
        var tooltip: DBusMessageIter
        if appendContainer(addr owner.api.functions, addr variant, DbusTypeStruct, nil, addr tooltip):
          valueOk = appendString(addr owner.api.functions, addr tooltip, "") and
            appendPixmap(addr owner.api.functions, addr tooltip, owner.icon) and
            appendString(addr owner.api.functions, addr tooltip, owner.title) and
            appendString(addr owner.api.functions, addr tooltip, "") and
            closeContainer(addr owner.api.functions, addr variant, addr tooltip)
    if not valueOk:
      if opened:
        abandonContainer(addr owner.api.functions, addr entry, addr variant)
      abandonContainer(addr owner.api.functions, addr properties, addr entry)
      abandonContainer(addr owner.api.functions, addr output, addr properties)
      owner.api.functions.messageUnref(reply)
      return
    if not closeContainer(addr owner.api.functions, addr entry, addr variant) or
        not closeContainer(addr owner.api.functions, addr properties, addr entry):
      abandonContainer(addr owner.api.functions, addr output, addr properties)
      owner.api.functions.messageUnref(reply)
      return
  if not closeContainer(addr owner.api.functions, addr output, addr properties):
    owner.api.functions.messageUnref(reply)
    return
  owner.sendMessage(reply)

proc dbusTrayMessage(connection: ptr DBusConnection; message: ptr DBusMessage;
                     userData: pointer): cint {.cdecl, gcsafe, raises: [].} =
  if connection == nil or message == nil or userData == nil:
    return DbusHandlerResultNotYetHandled
  let icon = cast[DbusTrayIcon](userData)
  if icon == nil or icon.owner.connection != connection:
    return DbusHandlerResultNotYetHandled
  let functions = addr icon.owner.api.functions
  let isActivate =
    functions[].messageIsMethodCall(message, SniInterface.cstring, "Activate".cstring) != 0'u32 or
    functions[].messageIsMethodCall(message, SniKdeInterface.cstring, "Activate".cstring) != 0'u32
  if isActivate:
    icon.owner.activationPending = true
    icon.owner.sendEmptyReply(message)
    return DbusHandlerResultHandled
  let isOtherInteraction =
    functions[].messageIsMethodCall(message, SniInterface.cstring, "ContextMenu".cstring) != 0'u32 or
    functions[].messageIsMethodCall(message, SniKdeInterface.cstring, "ContextMenu".cstring) != 0'u32 or
    functions[].messageIsMethodCall(message, SniInterface.cstring, "SecondaryActivate".cstring) != 0'u32 or
    functions[].messageIsMethodCall(message, SniKdeInterface.cstring, "SecondaryActivate".cstring) != 0'u32 or
    functions[].messageIsMethodCall(message, SniInterface.cstring, "Scroll".cstring) != 0'u32 or
    functions[].messageIsMethodCall(message, SniKdeInterface.cstring, "Scroll".cstring) != 0'u32
  if isOtherInteraction:
    icon.owner.sendEmptyReply(message)
    return DbusHandlerResultHandled
  if functions[].messageIsMethodCall(message, IntrospectableInterface.cstring, "Introspect".cstring) != 0'u32:
    let reply = functions[].messageNewMethodReturn(message)
    if reply != nil:
      var output: DBusMessageIter
      functions[].messageIterInitAppend(reply, addr output)
      if appendString(functions, addr output, IntrospectionXml):
        icon.owner.sendMessage(reply)
      else:
        functions[].messageUnref(reply)
    return DbusHandlerResultHandled
  if functions[].messageIsMethodCall(message, PropertiesInterface.cstring, "Get".cstring) != 0'u32:
    icon.owner.handlePropertiesGet(message)
    return DbusHandlerResultHandled
  if functions[].messageIsMethodCall(message, PropertiesInterface.cstring, "GetAll".cstring) != 0'u32:
    icon.owner.handlePropertiesGetAll(message)
    return DbusHandlerResultHandled
  DbusHandlerResultNotYetHandled

proc closeOwner(owner: var DbusTrayIconOwner): Result[Unit] =
  var first: HostError
  var failed = false
  if owner.connection != nil:
    if owner.pathRegistered:
      if owner.api.functions.connectionUnregisterObjectPath(
          owner.connection, SniObjectPath.cstring) == 0'u32:
        first = dbusTrayError("could not unregister the StatusNotifierItem object path")
        failed = true
      owner.pathRegistered = false
    if owner.nameOwned:
      var error: DBusError
      owner.api.functions.errorInit(addr error)
      discard owner.api.functions.busReleaseName(
        owner.connection, owner.serviceName.cstring, addr error)
      if owner.api.functions.errorIsSet(addr error) != 0'u32 and not failed:
        first = dbusTrayError("could not release the StatusNotifierItem bus name",
          errorDetail(addr owner.api.functions, error))
        failed = true
      owner.api.functions.errorFree(addr error)
      owner.nameOwned = false
    owner.api.functions.connectionClose(owner.connection)
    owner.api.functions.connectionUnref(owner.connection)
    owner.connection = nil
  var closed = owner.api.close()
  if not closed.isOk:
    if not failed:
      first = move(closed.error)
      failed = true
    else:
      first.context.add("; D-Bus library-close-failed=true")
  owner.connectionFd = -1
  owner.activationPending = false
  owner.icon = nil
  owner.serviceName = ""
  owner.title = ""
  if failed:
    failure[Unit](move(first))
  else:
    success()

proc cleanupFailure(owner: var DbusTrayIconOwner; primary: var HostError) =
  let cleanup = closeOwner(owner)
  if not cleanup.isOk:
    primary.context.add("; cleanup=" & cleanup.error.message)
    if cleanup.error.context.len > 0:
      primary.context.add(" (" & cleanup.error.context & ")")

proc registrationAttempt(owner: var DbusTrayIconOwner; serviceName,
                         interfaceName: cstring; failure: var string): bool =
  let message = owner.api.functions.messageNewMethodCall(
    serviceName, WatcherPath.cstring, interfaceName,
    "RegisterStatusNotifierItem".cstring)
  if message == nil:
    failure = "could not create the registration request"
    return false
  var arguments: DBusMessageIter
  owner.api.functions.messageIterInitAppend(message, addr arguments)
  if not appendString(addr owner.api.functions, addr arguments, owner.serviceName):
    owner.api.functions.messageUnref(message)
    failure = "could not encode the registration request"
    return false
  var error: DBusError
  owner.api.functions.errorInit(addr error)
  let reply = owner.api.functions.connectionSendWithReplyAndBlock(
    owner.connection, message, RegistrationTimeoutMilliseconds, addr error)
  owner.api.functions.messageUnref(message)
  if reply == nil:
    failure = errorDetail(addr owner.api.functions, error)
    owner.api.functions.errorFree(addr error)
    return false
  let replyType = owner.api.functions.messageGetType(reply)
  owner.api.functions.messageUnref(reply)
  if replyType == DbusMessageTypeError:
    failure = "watcher returned an error reply"
    owner.api.functions.errorFree(addr error)
    return false
  owner.api.functions.errorFree(addr error)
  true

proc sendRegistration(owner: var DbusTrayIconOwner): Result[Unit] =
  var freedesktopFailure: string
  if registrationAttempt(owner, WatcherService.cstring,
      WatcherInterface.cstring, freedesktopFailure):
    return success()
  var kdeFailure: string
  if registrationAttempt(owner, WatcherKdeService.cstring,
      WatcherKdeInterface.cstring, kdeFailure):
    return success()
  failure[Unit](dbusTrayError(
    "could not register with StatusNotifierWatcher",
    "freedesktop=" & freedesktopFailure & "; kde=" & kdeFailure))

proc `=destroy`(owner: var DbusTrayIconOwner) =
  doAssert owner.connection == nil and not owner.api.isOpen,
    "a D-Bus tray icon must be explicitly closed"

method open*(icon: DbusTrayIcon; title: string; image: GuiIcon): Result[Unit] {.
    raises: [].} =
  if icon == nil:
    return failure[Unit](dbusTrayError("D-Bus tray icon is not initialized"))
  if icon.owner.connection != nil or icon.owner.api.isOpen:
    return failure[Unit](dbusTrayError("D-Bus tray icon is already open"))
  if title.find('\0') >= 0:
    return failure[Unit](dbusTrayError("tray icon title contains a NUL byte"))
  if image == nil:
    return failure[Unit](dbusTrayError("tray icon requires a bounded image"))

  var opened = openDbusApi()
  if not opened.isOk:
    return failure[Unit](move(opened.error))
  icon.owner.api = move(opened.value)
  if icon.owner.api.functions.threadsInitDefault() == 0'u32:
    var primary = dbusTrayError("could not initialize libdbus thread support")
    cleanupFailure(icon.owner, primary)
    return failure[Unit](move(primary))

  var error: DBusError
  icon.owner.api.functions.errorInit(addr error)
  let connection = icon.owner.api.functions.busGetPrivate(DbusBusSession, addr error)
  if connection == nil:
    let detail = errorDetail(addr icon.owner.api.functions, error)
    icon.owner.api.functions.errorFree(addr error)
    var primary = dbusTrayError("could not connect to the session D-Bus", detail)
    cleanupFailure(icon.owner, primary)
    return failure[Unit](move(primary))
  icon.owner.api.functions.errorFree(addr error)
  icon.owner.connection = connection
  icon.owner.api.functions.connectionSetExitOnDisconnect(connection, 0'u32)
  icon.owner.title = title
  icon.owner.icon = image
  icon.owner.serviceName = SniServicePrefix & $int(getpid()) & "-1"

  icon.owner.api.functions.errorInit(addr error)
  let requestStatus = icon.owner.api.functions.busRequestName(
    connection, icon.owner.serviceName.cstring, DbusNameFlagDoNotQueue, addr error)
  if requestStatus notin [DbusRequestNameReplyPrimaryOwner, DbusRequestNameReplyAlreadyOwner] or
      icon.owner.api.functions.errorIsSet(addr error) != 0'u32:
    let detail = errorDetail(addr icon.owner.api.functions, error)
    icon.owner.api.functions.errorFree(addr error)
    var primary = dbusTrayError("could not acquire the StatusNotifierItem bus name", detail)
    cleanupFailure(icon.owner, primary)
    return failure[Unit](move(primary))
  icon.owner.api.functions.errorFree(addr error)
  icon.owner.nameOwned = true

  if icon.owner.api.functions.connectionRegisterObjectPath(
      connection, SniObjectPath.cstring, addr DbusTrayVTable,
      cast[pointer](icon)) == 0'u32:
    var primary = dbusTrayError("could not export the StatusNotifierItem object path")
    cleanupFailure(icon.owner, primary)
    return failure[Unit](move(primary))
  icon.owner.pathRegistered = true

  var fd: cint
  if icon.owner.api.functions.connectionGetUnixFd(connection, addr fd) == 0'u32 or fd < 0:
    var primary = dbusTrayError("could not obtain the session D-Bus descriptor")
    cleanupFailure(icon.owner, primary)
    return failure[Unit](move(primary))
  icon.owner.connectionFd = int32(fd)

  var registered = sendRegistration(icon.owner)
  if not registered.isOk:
    var primary = move(registered.error)
    cleanupFailure(icon.owner, primary)
    return failure[Unit](move(primary))
  icon.owner.api.functions.connectionFlush(connection)
  success()

method close*(icon: DbusTrayIcon): Result[Unit] {.raises: [].} =
  if icon == nil:
    return success()
  closeOwner(icon.owner)

method pollEvent*(icon: DbusTrayIcon): Result[TrayPollResult] {.
    raises: [].} =
  if icon == nil or icon.owner.connection == nil or not icon.owner.api.isOpen:
    return failure[TrayPollResult](dbusTrayError(
      "D-Bus tray event polling requires an open item"))
  if icon.owner.api.functions.connectionGetIsConnected(icon.owner.connection) == 0'u32:
    return success(TrayPollResult(available: true,
      event: TrayEvent(kind: tekClosed)))
  # With a zero timeout, libdbus may read a ready message into its internal
  # queue and return before dispatching it. Continue until no progress remains
  # so a request does not wait for another transport edge.
  for ignored in 0 ..< MaxDbusDispatchPerPoll:
    discard ignored
    if icon.owner.api.functions.connectionReadWriteDispatch(
        icon.owner.connection, 0) == 0'u32:
      break
  if icon.owner.api.functions.connectionGetIsConnected(icon.owner.connection) == 0'u32:
    return success(TrayPollResult(available: true,
      event: TrayEvent(kind: tekClosed)))
  if icon.owner.activationPending:
    icon.owner.activationPending = false
    return success(TrayPollResult(available: true,
      event: TrayEvent(kind: tekActivate)))
  success(TrayPollResult(available: false))

method fileDescriptor*(icon: DbusTrayIcon): int32 {.raises: [].} =
  if icon == nil or icon.owner.connection == nil:
    -1'i32
  else:
    icon.owner.connectionFd

proc newDbusTrayIcon*(): TrayIconBackend =
  var icon: DbusTrayIcon
  new(icon)
  icon

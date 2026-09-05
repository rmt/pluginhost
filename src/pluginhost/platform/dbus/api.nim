## Checked, move-only loading of the narrow libdbus-1 procedure table.

import ../../domain/[errors, result]
import ../linux/dynlib
import ./ffi

type
  DbusApi* = object
    library: DynamicLibrary
    functions*: DbusFunctions

proc `=destroy`*(api: var DbusApi) =
  `=destroy`(api.library)

proc `=copy`*(destination: var DbusApi; source: DbusApi) {.error:
  "DbusApi owns a dynamic library and cannot be copied; use move".}
proc `=dup`*(source: DbusApi): DbusApi {.error:
  "DbusApi owns a dynamic library and cannot be duplicated; use move".}

proc `=sink`*(destination: var DbusApi; source: DbusApi) =
  doAssert not destination.library.isOpen,
    "an open DbusApi must be closed before move assignment"
  `=sink`(destination.library, source.library)
  destination.functions = source.functions

proc isOpen*(api: DbusApi): bool {.inline.} =
  api.library.isOpen

proc libraryPath*(api: DbusApi): string {.inline.} =
  api.library.libraryPath

proc dbusApiError(kind: HostErrorKind; message, path: string;
                  platformError: HostError): HostError =
  var context = "library=" & path
  if platformError.context.len > 0:
    context.add("; " & platformError.context)
  hostError(hsGui, kind, message, context)

proc close*(api: var DbusApi): Result[Unit] =
  if not api.library.isOpen:
    api.functions = default(DbusFunctions)
    return success()
  let closed = api.library.close()
  if not closed.isOk:
    return failure[Unit](dbusApiError(
      hekLibraryClose, "could not unload the D-Bus client library",
      api.library.libraryPath, closed.error))
  api.functions = default(DbusFunctions)
  success()

proc rollback(api: var DbusApi; primary: HostError): HostError =
  let cleanup = api.close()
  if cleanup.isOk:
    return primary
  result = cleanup.error
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc openDbusApi*(path = DbusLibrary): Result[DbusApi] =
  var opened = openDynamicLibrary(path)
  if not opened.isOk:
    return failure[DbusApi](dbusApiError(
      hekLibraryOpen, "could not load the D-Bus client library", path,
      opened.error))

  var api = DbusApi(library: move(opened.value))
  template resolveRequired(field: untyped; procedureType: typedesc;
                           symbol: static string) =
    block:
      let resolved = resolveSymbol[procedureType](api.library, symbol)
      if not resolved.isOk:
        let primary = dbusApiError(
          hekSymbolLookup, "required D-Bus symbol is unavailable", path,
          resolved.error)
        return failure[DbusApi](api.rollback(primary))
      api.functions.field = resolved.value

  resolveRequired(threadsInitDefault, DBusThreadsInitDefaultProc,
    "dbus_threads_init_default")
  resolveRequired(busGetPrivate, DBusBusGetPrivateProc, "dbus_bus_get_private")
  resolveRequired(busRequestName, DBusBusRequestNameProc, "dbus_bus_request_name")
  resolveRequired(busReleaseName, DBusBusReleaseNameProc, "dbus_bus_release_name")
  resolveRequired(connectionSetExitOnDisconnect,
    DBusConnectionSetExitOnDisconnectProc,
    "dbus_connection_set_exit_on_disconnect")
  resolveRequired(connectionGetIsConnected, DBusConnectionGetIsConnectedProc,
    "dbus_connection_get_is_connected")
  resolveRequired(connectionGetUnixFd, DBusConnectionGetUnixFdProc,
    "dbus_connection_get_unix_fd")
  resolveRequired(connectionReadWriteDispatch,
    DBusConnectionReadWriteDispatchProc,
    "dbus_connection_read_write_dispatch")
  resolveRequired(connectionClose, DBusConnectionCloseProc,
    "dbus_connection_close")
  resolveRequired(connectionUnref, DBusConnectionUnrefProc,
    "dbus_connection_unref")
  resolveRequired(connectionSendWithReplyAndBlock,
    DBusConnectionSendWithReplyAndBlockProc,
    "dbus_connection_send_with_reply_and_block")
  resolveRequired(connectionSend, DBusConnectionSendProc, "dbus_connection_send")
  resolveRequired(connectionFlush, DBusConnectionFlushProc, "dbus_connection_flush")
  resolveRequired(connectionRegisterObjectPath,
    DBusConnectionRegisterObjectPathProc,
    "dbus_connection_register_object_path")
  resolveRequired(connectionUnregisterObjectPath,
    DBusConnectionUnregisterObjectPathProc,
    "dbus_connection_unregister_object_path")
  resolveRequired(messageNewMethodCall, DBusMessageNewMethodCallProc,
    "dbus_message_new_method_call")
  resolveRequired(messageNewMethodReturn, DBusMessageNewMethodReturnProc,
    "dbus_message_new_method_return")
  resolveRequired(messageNewError, DBusMessageNewErrorProc,
    "dbus_message_new_error")
  resolveRequired(messageUnref, DBusMessageUnrefProc, "dbus_message_unref")
  resolveRequired(messageGetInterface, DBusMessageGetInterfaceProc,
    "dbus_message_get_interface")
  resolveRequired(messageGetMember, DBusMessageGetMemberProc,
    "dbus_message_get_member")
  resolveRequired(messageGetType, DBusMessageGetTypeProc, "dbus_message_get_type")
  resolveRequired(messageIsMethodCall, DBusMessageIsMethodCallProc,
    "dbus_message_is_method_call")
  resolveRequired(errorInit, DBusErrorInitProc, "dbus_error_init")
  resolveRequired(errorFree, DBusErrorFreeProc, "dbus_error_free")
  resolveRequired(errorIsSet, DBusErrorIsSetProc, "dbus_error_is_set")
  resolveRequired(messageIterInit, DBusMessageIterInitProc,
    "dbus_message_iter_init")
  resolveRequired(messageIterInitAppend, DBusMessageIterInitAppendProc,
    "dbus_message_iter_init_append")
  resolveRequired(messageIterHasNext, DBusMessageIterHasNextProc,
    "dbus_message_iter_has_next")
  resolveRequired(messageIterNext, DBusMessageIterNextProc,
    "dbus_message_iter_next")
  resolveRequired(messageIterAbandonContainer,
    DBusMessageIterAbandonContainerProc,
    "dbus_message_iter_abandon_container")
  resolveRequired(messageIterGetArgType, DBusMessageIterGetArgTypeProc,
    "dbus_message_iter_get_arg_type")
  resolveRequired(messageIterGetBasic, DBusMessageIterGetBasicProc,
    "dbus_message_iter_get_basic")
  resolveRequired(messageIterAppendBasic, DBusMessageIterAppendBasicProc,
    "dbus_message_iter_append_basic")
  resolveRequired(messageIterOpenContainer, DBusMessageIterOpenContainerProc,
    "dbus_message_iter_open_container")
  resolveRequired(messageIterCloseContainer, DBusMessageIterCloseContainerProc,
    "dbus_message_iter_close_container")
  resolveRequired(messageIterAppendFixedArray,
    DBusMessageIterAppendFixedArrayProc,
    "dbus_message_iter_append_fixed_array")
  resolveRequired(messageIterRecurse, DBusMessageIterRecurseProc,
    "dbus_message_iter_recurse")

  success(move(api))

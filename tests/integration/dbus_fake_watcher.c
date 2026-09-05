#include <dbus/dbus.h>
#include <stdbool.h>

#include <stdio.h>
#include <string.h>

static const char *watcher_name = "org.freedesktop.StatusNotifierWatcher";
static const char *watcher_path = "/StatusNotifierWatcher";
static const char *watcher_interface = "org.freedesktop.StatusNotifierWatcher";
static const char *item_path = "/StatusNotifierItem";
static const char *item_interface = "org.freedesktop.StatusNotifierItem";
static bool send_activation = true;

static void send_activate(DBusConnection *connection, const char *service) {
   DBusMessage *message = dbus_message_new_method_call(
       service, item_path, item_interface, "Activate");
   if (message == NULL) {
      return;
   }
   dbus_int32_t x = 0;
   dbus_int32_t y = 0;
   dbus_message_append_args(message,
                            DBUS_TYPE_INT32, &x,
                            DBUS_TYPE_INT32, &y,
                            DBUS_TYPE_INVALID);
   dbus_connection_send(connection, message, NULL);
   dbus_connection_flush(connection);
   dbus_message_unref(message);
}

static DBusHandlerResult handle_message(DBusConnection *connection,
                                         DBusMessage *message,
                                         void *user_data) {
   (void)user_data;
   if (!dbus_message_is_method_call(message, watcher_interface,
                                    "RegisterStatusNotifierItem")) {
      return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
   }

   DBusMessageIter arguments;
   const char *service = NULL;
   if (!dbus_message_iter_init(message, &arguments) ||
       dbus_message_iter_get_arg_type(&arguments) != DBUS_TYPE_STRING) {
      DBusMessage *error = dbus_message_new_error(
          message, DBUS_ERROR_INVALID_ARGS, "expected item service name");
      if (error != NULL) {
         dbus_connection_send(connection, error, NULL);
         dbus_message_unref(error);
      }
      return DBUS_HANDLER_RESULT_HANDLED;
   }
   dbus_message_iter_get_basic(&arguments, &service);
   if (service == NULL || service[0] == '\0') {
      return DBUS_HANDLER_RESULT_HANDLED;
   }

   DBusMessage *reply = dbus_message_new_method_return(message);
   if (reply != NULL) {
      dbus_connection_send(connection, reply, NULL);
      dbus_message_unref(reply);
   }
   printf("REGISTER %s\n", service);
   fflush(stdout);
   if (send_activation)
      send_activate(connection, service);
   return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusObjectPathVTable vtable = {
   .unregister_function = NULL,
   .message_function = handle_message,
   .dbus_internal_pad1 = NULL,
   .dbus_internal_pad2 = NULL,
   .dbus_internal_pad3 = NULL,
   .dbus_internal_pad4 = NULL,
};
int main(int argc, char **argv) {
   for (int index = 1; index < argc; ++index) {
      if (strcmp(argv[index], "kde") == 0) {
         watcher_name = "org.kde.StatusNotifierWatcher";
         watcher_interface = "org.kde.StatusNotifierWatcher";
         item_interface = "org.kde.StatusNotifierItem";
      } else if (strcmp(argv[index], "no-activate") == 0) {
         send_activation = false;
      }
   }
   DBusError error;
   dbus_error_init(&error);
   if (!dbus_threads_init_default()) {
      fprintf(stderr, "dbus_threads_init_default failed\n");
      return 1;
   }
   DBusConnection *connection = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
   if (connection == NULL) {
      fprintf(stderr, "session connection failed: %s\n",
              error.message != NULL ? error.message : "unknown");
      dbus_error_free(&error);
      return 1;
   }
   dbus_connection_set_exit_on_disconnect(connection, FALSE);
   int result = dbus_bus_request_name(connection, watcher_name,
                                      DBUS_NAME_FLAG_DO_NOT_QUEUE, &error);
   if (dbus_error_is_set(&error) || result != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
      fprintf(stderr, "watcher name failed: %s\n",
              error.message != NULL ? error.message : "not primary owner");
      dbus_error_free(&error);
      dbus_connection_close(connection);
      dbus_connection_unref(connection);
      return 1;
   }
   if (!dbus_connection_register_object_path(connection, watcher_path,
                                              &vtable, NULL)) {
      fprintf(stderr, "watcher object registration failed\n");
      dbus_bus_release_name(connection, watcher_name, NULL);
      dbus_connection_close(connection);
      dbus_connection_unref(connection);
      return 1;
   }
   puts("READY");
   fflush(stdout);
   for (;;) {
      if (!dbus_connection_read_write_dispatch(connection, -1)) {
         break;
      }
   }
   dbus_bus_release_name(connection, watcher_name, NULL);
   dbus_connection_close(connection);
   dbus_connection_unref(connection);
   return 0;
}

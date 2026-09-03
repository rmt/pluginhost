#include <stdlib.h>

#include <X11/Xlib.h>

int main(int argc, char **argv) {
   if (argc != 2) {
      return 2;
   }

   char *end = NULL;
   unsigned long window_value = strtoul(argv[1], &end, 10);
   if (end == argv[1] || *end != '\0' || window_value == 0) {
      return 2;
   }

   Display *display = XOpenDisplay(NULL);
   if (display == NULL) {
      return 3;
   }

   Atom wm_protocols = XInternAtom(display, "WM_PROTOCOLS", False);
   Atom wm_delete = XInternAtom(display, "WM_DELETE_WINDOW", False);
   if (wm_protocols == None || wm_delete == None) {
      (void)XCloseDisplay(display);
      return 4;
   }

   XClientMessageEvent message = {0};
   message.type = ClientMessage;
   message.display = display;
   message.window = (Window)window_value;
   message.message_type = wm_protocols;
   message.format = 32;
   message.data.l[0] = (long)wm_delete;

   Status sent = XSendEvent(display, message.window, False, 0,
                            (XEvent *)&message);
   int flushed = XFlush(display);
   int closed = XCloseDisplay(display);
   if (sent == 0 || flushed == 0 || closed != 0) {
      return 5;
   }
   return 0;
}

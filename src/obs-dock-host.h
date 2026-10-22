#pragma once

#import <AppKit/AppKit.h>
#include <stdbool.h>

typedef void (^LBDockVisibilityCallback)(bool visible);
typedef void (^LBDockDeactivateCallback)(void);

#ifdef __cplusplus
extern "C" {
#endif

// Safe for standalone libobs: checks for QApplication before the frontend API.
bool lb_dock_frontend_available(void);

// Calls are synchronous on the Cocoa/Qt main thread. OBS owns the registered
// QDockWidget. The host retains content until destroy; the caller may retain it
// too. Callbacks are copied: weakly capture a controller that owns this handle.
// Registration leaves visibility and floating state to OBS's saved layout.
// Returns NULL if the frontend is absent, the ID is in use, or embedding fails.
void *lb_dock_create(const char *id, const char *title, NSView *content,
                     LBDockVisibilityCallback on_visible,
                     LBDockDeactivateCallback on_deactivate);
void lb_dock_show(void *host);
bool lb_dock_is_visible(void *host);
void lb_dock_destroy(void *host);

// Explicit Tools-menu action for this plugin only. Return its dock to the
// docks on the right, leaving all other docks alone. Never call on startup.
void lb_dock_group_in_main_window(void);

#ifdef __cplusplus
}
#endif

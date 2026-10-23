#pragma once

#include <stddef.h>
#include <obs.h>

// Register an OBS dock once the frontend exists; standalone libobs stays headless.
void lb_panel_register_dock(void);
void lb_panel_refresh_sources(void);
void lb_panel_show(void);
void lb_panel_shutdown(void);
const char *lb_filter_id(void);
void lb_filter_copy_status(obs_source_t *source, char *buffer, size_t capacity);

void lb_panel_prepare_resources(void);

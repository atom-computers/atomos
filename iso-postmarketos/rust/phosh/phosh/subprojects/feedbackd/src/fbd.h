#pragma once

#include <glib-object.h>

G_BEGIN_DECLS

/*
 * The udev attribute and values devices must have to be handled by
 *  fbd feedbackd
 */
#define FEEDBACKD_UDEV_ATTR    "FEEDBACKD_TYPE"
#define FEEDBACKD_UDEV_VAL_LED "led"

#define FEEDBACKD_SCHEMA_ID "org.sigxcpu.feedbackd"

typedef enum {
    FBD_ERROR_FAILED = 0,
    FBD_ERROR_THEME_EXPAND = 1,
} FbdError;

GQuark fbd_error_quark (void);

G_END_DECLS

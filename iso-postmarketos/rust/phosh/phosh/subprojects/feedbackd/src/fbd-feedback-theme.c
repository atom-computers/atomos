/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-theme"

#include "fbd-feedback-base.h"
#include "fbd-feedback-dummy.h"
#include "fbd-feedback-sound.h"
#include "fbd-feedback-theme.h"
#include "fbd-feedback-vibra.h"
#include "fbd-feedback-profile.h"

#include <json-glib/json-glib.h>

enum {
  PROP_0,
  PROP_NAME,
  PROP_PARENT_NAME,
  PROP_PROFILES,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

typedef struct _FbdFeedbackTheme {
  GObject parent;

  char *name;
  char *parent_name;

  GHashTable *profiles;
} FbdFeedbackTheme;

static void json_serializable_iface_init (JsonSerializableIface *iface);

G_DEFINE_TYPE_WITH_CODE (FbdFeedbackTheme, fbd_feedback_theme, G_TYPE_OBJECT,
			 G_IMPLEMENT_INTERFACE (JSON_TYPE_SERIALIZABLE,
                                                json_serializable_iface_init));


static JsonNode *
fbd_theme_serializable_serialize_property (JsonSerializable *serializable,
					   const gchar      *property_name,
					   const GValue     *value,
					   GParamSpec       *pspec)
{
  FbdFeedbackTheme *self = FBD_FEEDBACK_THEME (serializable);
  JsonNode *node = NULL;

  if (g_strcmp0 (property_name, "profiles") == 0) {
    GHashTableIter iter;
    gpointer key;
    FbdFeedbackProfile *profile;
    g_autoptr (JsonArray) array = json_array_sized_new (FBD_FEEDBACK_PROFILE_N_PROFILES);

    g_hash_table_iter_init (&iter, self->profiles);
    while (g_hash_table_iter_next (&iter, (gpointer *)&key, (gpointer *) &profile)) {
      json_array_add_element (array, json_gobject_serialize (G_OBJECT(profile)));
    }
    node = json_node_init_array (json_node_alloc (), array);
  } else {
    node = json_serializable_default_serialize_property (serializable,
							 property_name,
							 value,
							 pspec);
  }
  return node;
}

static gboolean
fbd_theme_serializable_deserialize_property (JsonSerializable *serializable,
					     const gchar      *property_name,
					     GValue           *value,
					     GParamSpec       *pspec,
					     JsonNode         *property_node)
{
  if (g_strcmp0 (property_name, "profiles") == 0) {
    if (JSON_NODE_TYPE (property_node) == JSON_NODE_NULL) {
      g_value_set_pointer (value, NULL);
      return TRUE;
    } else if (JSON_NODE_TYPE (property_node) == JSON_NODE_ARRAY) {
      JsonArray *array = json_node_get_array (property_node);
      guint i, array_len = json_array_get_length (array);
      GHashTable *profiles = g_hash_table_new_full (g_str_hash,
						    g_str_equal,
						    g_free,
						    (GDestroyNotify)g_object_unref);

      for (i = 0; i < array_len; i++) {
	JsonNode *element_node = json_array_get_element (array, i);
	FbdFeedbackProfile *profile;
	gchar *name;

	if (JSON_NODE_HOLDS_OBJECT (element_node)) {
	  profile = FBD_FEEDBACK_PROFILE (json_gobject_deserialize (FBD_TYPE_FEEDBACK_PROFILE,
								    element_node));
	  name = g_strdup (fbd_feedback_profile_get_name (profile));
	  g_hash_table_insert (profiles, name, profile);
	} else {
	  return FALSE;
	}
      }
      g_value_set_boxed (value, profiles);
      return TRUE;
    }
    return FALSE;
  } else {
    return json_serializable_default_deserialize_property (serializable,
							   property_name,
							   value,
							   pspec,
							   property_node);
  }
  return FALSE;
}

static void
fbd_feedback_theme_set_property (GObject      *object,
                                 guint         property_id,
                                 const GValue *value,
                                 GParamSpec   *pspec)
{
  FbdFeedbackTheme *self = FBD_FEEDBACK_THEME (object);

  switch (property_id) {
  case PROP_NAME:
    fbd_feedback_theme_set_name (self, g_value_get_string (value));
    break;
  case PROP_PARENT_NAME:
    fbd_feedback_theme_set_parent_name (self, g_value_get_string (value));
    break;
  case PROP_PROFILES:
    if (self->profiles)
      g_hash_table_unref (self->profiles);
    self->profiles = g_value_get_boxed (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_feedback_theme_get_property (GObject  *object,
                                 guint       property_id,
                                 GValue     *value,
                                 GParamSpec *pspec)
{
  FbdFeedbackTheme *self = FBD_FEEDBACK_THEME (object);

  switch (property_id) {
  case PROP_NAME:
    g_value_set_string (value, fbd_feedback_theme_get_name (self));
    break;
  case PROP_PARENT_NAME:
    g_value_set_string (value, fbd_feedback_theme_get_parent_name (self));
    break;
  case PROP_PROFILES:
    g_value_set_boxed (value, self->profiles);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_theme_dispose (GObject *object)
{
  FbdFeedbackTheme *self = FBD_FEEDBACK_THEME (object);

  g_clear_pointer (&self->profiles, g_hash_table_unref);

  G_OBJECT_CLASS (fbd_feedback_theme_parent_class)->dispose (object);
}

static void
fbd_feedback_theme_finalize (GObject *object)
{
  FbdFeedbackTheme *self = FBD_FEEDBACK_THEME (object);

  g_clear_pointer (&self->parent_name, g_free);
  g_clear_pointer (&self->name, g_free);

  G_OBJECT_CLASS (fbd_feedback_theme_parent_class)->finalize (object);
}

static void
json_serializable_iface_init (JsonSerializableIface *iface)
{
  iface->serialize_property = fbd_theme_serializable_serialize_property;
  iface->deserialize_property = fbd_theme_serializable_deserialize_property;
}

static void
fbd_feedback_theme_class_init (FbdFeedbackThemeClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = fbd_feedback_theme_set_property;
  object_class->get_property = fbd_feedback_theme_get_property;

  object_class->dispose = fbd_feedback_theme_dispose;
  object_class->finalize = fbd_feedback_theme_finalize;

  props[PROP_NAME] =
    g_param_spec_string (
      "name",
      "Name",
      "The theme name",
      NULL,
      G_PARAM_EXPLICIT_NOTIFY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_PARENT_NAME] =
    g_param_spec_string (
      "parent-name",
      "Parent theme Name",
      "The parent theme name",
      NULL,
      G_PARAM_EXPLICIT_NOTIFY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_PROFILES] =
    g_param_spec_boxed (
      "profiles",
      "Profiles",
      "The feedback profiles",
      G_TYPE_HASH_TABLE,
      /* Can't be CONSTRUCT_ONLY since json-glib can't handle it */
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}

static void
fbd_feedback_theme_init (FbdFeedbackTheme *self)
{
  self->profiles = g_hash_table_new_full (g_str_hash,
                                          g_str_equal,
                                          g_free,
                                          (GDestroyNotify)g_object_unref);
}

FbdFeedbackTheme *
fbd_feedback_theme_new (const gchar *name)
{
  return FBD_FEEDBACK_THEME (g_object_new (FBD_TYPE_FEEDBACK_THEME,
                                           "name", name,
                                           NULL));
}


FbdFeedbackTheme *
fbd_feedback_theme_new_from_data (const gchar *data, GError **error)
{
  g_autoptr (JsonNode) node = json_from_string(data, error);
  if (!node)
    return NULL;

  return FBD_FEEDBACK_THEME (json_gobject_deserialize (FBD_TYPE_FEEDBACK_THEME, node));
}


FbdFeedbackTheme *
fbd_feedback_theme_new_from_file (const gchar *filename, GError **error)
{
  g_autofree char *data = NULL;

  if (!g_file_get_contents (filename, &data, NULL, error))
    return NULL;

  return fbd_feedback_theme_new_from_data (data, error);
}

void
fbd_feedback_theme_set_name (FbdFeedbackTheme *self, const char *name)
{
  g_return_if_fail (FBD_IS_FEEDBACK_THEME (self));

  if (g_strcmp0 (self->name, name) == 0)
    return;

  g_free (self->name);
  self->name = g_strdup (name);

  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_NAME]);
}

const char *
fbd_feedback_theme_get_name (FbdFeedbackTheme *self)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_THEME (self), "");

  return self->name;
}


void
fbd_feedback_theme_set_parent_name (FbdFeedbackTheme *self, const char *parent_name)
{
  g_return_if_fail (FBD_IS_FEEDBACK_THEME (self));

  if (g_strcmp0 (self->parent_name, parent_name) == 0)
    return;

  g_free (self->parent_name);
  self->parent_name = g_strdup (parent_name);

  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_PARENT_NAME]);
}


const char *
fbd_feedback_theme_get_parent_name (FbdFeedbackTheme *self)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_THEME (self), "");

  return self->parent_name;
}


void
fbd_feedback_theme_add_profile (FbdFeedbackTheme *self, FbdFeedbackProfile *profile)
{
  gchar *name;

  g_return_if_fail (FBD_IS_FEEDBACK_THEME (self));
  g_return_if_fail (FBD_IS_FEEDBACK_PROFILE (profile));
  name = g_strdup (fbd_feedback_profile_get_name (profile));

  g_hash_table_insert (self->profiles, name, g_object_ref (profile));
}

FbdFeedbackProfile *
fbd_feedback_theme_get_profile (FbdFeedbackTheme *self, const char *name)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_THEME (self), NULL);

  return g_hash_table_lookup (self->profiles, name);
}

GSList *
fbd_feedback_theme_lookup_feedback (FbdFeedbackTheme *self,
                                    FbdFeedbackProfileLevel level,
                                    FbdEvent *event)
{
  GSList *feedbacks = NULL;

  for (int i = level; i >= FBD_FEEDBACK_PROFILE_LEVEL_SILENT; i--) {
    const char *profile_name = fbd_feedback_profile_level_to_string (i);
    FbdFeedbackProfile *profile = fbd_feedback_theme_get_profile (self, profile_name);
    FbdFeedbackBase *feedback = fbd_feedback_profile_get_feedback (profile,
								   fbd_event_get_event (event));
    if (feedback) {
      g_object_set_data (G_OBJECT (feedback), "fbd-level", GUINT_TO_POINTER (i));
      feedbacks = g_slist_prepend (feedbacks, g_object_ref (feedback));
    }
  }

  if (!g_slist_length (feedbacks))
    g_debug ("No feedback for event %s", fbd_event_get_event (event));
  return feedbacks;
}


/**
 * fbd_feedback_theme_update:
 * @self: The feedback theme that should be updated
 * @new: The feedback theme we want to take profiles and feedbacks new
 *
 * Merges two feedback themes. Feedbacks and profiles are read new
 * the `new` theme.  If feedback already exists in the same profile
 * of `self` it is overwritten with the feedback in `new`.
 */
void
fbd_feedback_theme_update (FbdFeedbackTheme *self, FbdFeedbackTheme *new)
{
  GHashTableIter iter;
  const char *profile_name;
  FbdFeedbackProfile *profile;

  g_return_if_fail (FBD_IS_FEEDBACK_THEME (self));
  g_return_if_fail (FBD_IS_FEEDBACK_THEME (new));

  fbd_feedback_theme_set_name (self, fbd_feedback_theme_get_name (new));

  g_hash_table_iter_init (&iter, new->profiles);
  while (g_hash_table_iter_next (&iter, (gpointer)&profile_name, (gpointer)&profile)) {
    FbdFeedbackProfile *current;

    current = g_hash_table_lookup (self->profiles, profile_name);
    if (current == NULL) {
      current = fbd_feedback_profile_new (profile_name);
      g_hash_table_insert (self->profiles,
                           g_strdup (profile_name),
                           current);
    }

    fbd_feedback_profile_update (current, profile);
  }
}

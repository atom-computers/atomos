/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-profile"

#include "fbd-feedback-dummy.h"
#include "fbd-feedback-profile.h"
#include "fbd-feedback-sound.h"
#include "fbd-feedback-led.h"
#include "fbd-feedback-vibra-pattern.h"
#include "fbd-feedback-vibra-periodic.h"
#include "fbd-feedback-vibra-rumble.h"

#include <json-glib/json-glib.h>

#define FBD_FEEDBACK_CLS_PREFIX "FbdFeedback"

enum {
  PROP_0,
  PROP_NAME,
  PROP_FEEDBACKS,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

/**
 * SECTION:fbd-feedback-profile
 * @short_description: A profile in a #FbdFeedbackTheme
 * @Title: FbdFeedbackProfile
 */

typedef struct _FbdFeedbackProfile {
  GObject parent;

  gchar *name;
  GHashTable *feedbacks; /* key: event name, value: feedback */
} FbdFeedbackProfile;

static void json_serializable_iface_init (JsonSerializableIface *iface);

G_DEFINE_TYPE_WITH_CODE (FbdFeedbackProfile, fbd_feedback_profile, G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (JSON_TYPE_SERIALIZABLE,
                                                json_serializable_iface_init));


static JsonNode *
fbd_feedback_profile_serializable_serialize_property (JsonSerializable *serializable,
                                                      const gchar *property_name,
                                                      const GValue *value,
                                                      GParamSpec *pspec)
{
  FbdFeedbackProfile *self = FBD_FEEDBACK_PROFILE (serializable);
  JsonNode *node = NULL;

  if (g_strcmp0 (property_name, "feedbacks") == 0) {
    GHashTableIter iter;
    gpointer key;
    FbdFeedbackProfile *profile;
    g_autoptr (JsonArray) array = json_array_sized_new (FBD_FEEDBACK_PROFILE_N_PROFILES);

    g_hash_table_iter_init (&iter, self->feedbacks);
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

static GType
feedback_get_type (JsonNode *feedback_node)
{
  g_autofree gchar *type_name = NULL;
  JsonObject *obj = json_node_get_object (feedback_node);
  JsonNode *type_node = json_object_get_member (obj, "type");
  GType gtype = 0;

  /* Ensure all feedback types so the json parsing can use them */
  g_type_ensure (FBD_TYPE_FEEDBACK_DUMMY);
  g_type_ensure (FBD_TYPE_FEEDBACK_LED);
  g_type_ensure (FBD_TYPE_FEEDBACK_VIBRA_PATTERN);
  g_type_ensure (FBD_TYPE_FEEDBACK_VIBRA_PERIODIC);
  g_type_ensure (FBD_TYPE_FEEDBACK_VIBRA_RUMBLE);
  g_type_ensure (FBD_TYPE_FEEDBACK_SOUND);

  g_return_val_if_fail (type_node, FBD_TYPE_FEEDBACK_DUMMY);

  type_name = g_strdup_printf ("FbdFeedback%s",
                               json_node_get_string (type_node));
  type_name[strlen(FBD_FEEDBACK_CLS_PREFIX)] =
    g_ascii_toupper (type_name[strlen(FBD_FEEDBACK_CLS_PREFIX)]);
  gtype = g_type_from_name (type_name);

  g_debug ("Feedback %s, type %" G_GSIZE_FORMAT, type_name, gtype);
  g_return_val_if_fail (gtype, FBD_TYPE_FEEDBACK_DUMMY);
  return gtype;
}

static gboolean
fbd_feedback_profile_serializable_deserialize_property (JsonSerializable *serializable,
                                                        const gchar *property_name,
                                                        GValue *value,
                                                        GParamSpec *pspec,
                                                        JsonNode *property_node)
{
  if (g_strcmp0 (property_name, "feedbacks") == 0) {
    if (JSON_NODE_TYPE (property_node) == JSON_NODE_NULL) {
      g_value_set_pointer (value, NULL);
      return TRUE;
    } else if (JSON_NODE_TYPE (property_node) == JSON_NODE_ARRAY) {
      JsonArray *array = json_node_get_array (property_node);
      guint i, array_len = json_array_get_length (array);
      GHashTable *feedbacks = g_hash_table_new_full (g_str_hash,
                                                     g_str_equal,
                                                     g_free,
                                                     (GDestroyNotify)g_object_unref);
      for (i = 0; i < array_len; i++) {
        JsonNode *element_node = json_array_get_element (array, i);

        if (JSON_NODE_HOLDS_OBJECT (element_node)) {
          gchar *event_name;
          FbdFeedbackBase *feedback;
          GType gtype = feedback_get_type (element_node);

          feedback = FBD_FEEDBACK_BASE (json_gobject_deserialize (gtype, element_node));
          event_name = g_strdup (fbd_feedback_get_event_name (FBD_FEEDBACK_BASE(feedback)));
          g_hash_table_insert (feedbacks, event_name, feedback);
        } else {
          return FALSE;
        }
      }
      g_value_set_boxed (value, feedbacks);
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
fbd_feedback_profile_set_property (GObject        *object,
                                   guint         property_id,
                                   const GValue *value,
                                   GParamSpec   *pspec)
{
  FbdFeedbackProfile *self = FBD_FEEDBACK_PROFILE (object);

  switch (property_id) {
  case PROP_NAME:
    g_free (self->name);
    self->name = g_value_dup_string (value);
    break;
  case PROP_FEEDBACKS:
    if (self->feedbacks)
      g_hash_table_unref (self->feedbacks);
    self->feedbacks = g_value_get_boxed (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_feedback_profile_get_property (GObject  *object,
                                   guint       property_id,
                                   GValue     *value,
                                   GParamSpec *pspec)
{
  FbdFeedbackProfile *self = FBD_FEEDBACK_PROFILE (object);

  switch (property_id) {
  case PROP_NAME:
    g_value_set_string (value, self->name);
    break;
  case PROP_FEEDBACKS:
    g_value_set_boxed (value, self->feedbacks);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_profile_dispose (GObject *object)
{
  FbdFeedbackProfile *self = FBD_FEEDBACK_PROFILE (object);

  g_clear_pointer (&self->feedbacks, g_hash_table_unref);

  G_OBJECT_CLASS (fbd_feedback_profile_parent_class)->dispose (object);
}

static void
fbd_feedback_profile_finalize (GObject *object)
{
  FbdFeedbackProfile *self = FBD_FEEDBACK_PROFILE (object);

  g_clear_pointer (&self->name, g_free);

  G_OBJECT_CLASS (fbd_feedback_profile_parent_class)->finalize (object);
}

static void
json_serializable_iface_init (JsonSerializableIface *iface)
{
  iface->serialize_property = fbd_feedback_profile_serializable_serialize_property;
  iface->deserialize_property = fbd_feedback_profile_serializable_deserialize_property;
}

static void
fbd_feedback_profile_constructed (GObject *object)
{
  FbdFeedbackProfile *self = FBD_FEEDBACK_PROFILE (object);

  G_OBJECT_CLASS (fbd_feedback_profile_parent_class)->constructed (object);

  if (!self->feedbacks) {
    self->feedbacks = g_hash_table_new_full (g_str_hash,
                                             g_str_equal,
                                             g_free,
                                             (GDestroyNotify)g_object_unref);
  }
}


static void
fbd_feedback_profile_class_init (FbdFeedbackProfileClass *klass)
{

  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = fbd_feedback_profile_set_property;
  object_class->get_property = fbd_feedback_profile_get_property;

  object_class->constructed = fbd_feedback_profile_constructed;
  object_class->dispose = fbd_feedback_profile_dispose;
  object_class->finalize = fbd_feedback_profile_finalize;

  props[PROP_NAME] =
    g_param_spec_string (
      "name",
      "Name",
      "The feedback name",
      NULL,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_FEEDBACKS] =
    g_param_spec_boxed (
      "feedbacks",
      "Feedbacks",
      "The feedbacks for this profile",
      G_TYPE_HASH_TABLE,
      /* Can't be CONSTRUCT_ONLY since json-glib can't handle it */
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}

static void
fbd_feedback_profile_init (FbdFeedbackProfile *self)
{
}

FbdFeedbackProfile *
fbd_feedback_profile_new (const gchar *name)
{
  return g_object_new(FBD_TYPE_FEEDBACK_PROFILE,
                      "name", name,
                      NULL);
}

const char *
fbd_feedback_profile_get_name (FbdFeedbackProfile *self)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_PROFILE (self), "");

  return self->name;
}

void
fbd_feedback_profile_add_feedback (FbdFeedbackProfile *self, FbdFeedbackBase *feedback)
{
  g_return_if_fail (FBD_IS_FEEDBACK_PROFILE (self));
  gchar *name = g_strdup (fbd_feedback_get_event_name (feedback));

  /* TODO: allow for more than one feedback per event and profile */
  g_hash_table_insert (self->feedbacks, name, g_object_ref (feedback));
}

FbdFeedbackBase *
fbd_feedback_profile_get_feedback (FbdFeedbackProfile *self, const char *event_name)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_PROFILE (self), NULL);

  return g_hash_table_lookup (self->feedbacks, event_name);
}

FbdFeedbackProfileLevel
fbd_feedback_profile_level (const char *name)
{
  FbdFeedbackProfileLevel profile = FBD_FEEDBACK_PROFILE_LEVEL_UNKNOWN;

  if (!g_strcmp0("silent", name)) {
    profile = FBD_FEEDBACK_PROFILE_LEVEL_SILENT;
  } else if (!g_strcmp0("quiet", name)) {
    profile = FBD_FEEDBACK_PROFILE_LEVEL_QUIET;
  } else if (!g_strcmp0("full", name)) {
    profile = FBD_FEEDBACK_PROFILE_LEVEL_FULL;
  }

  return profile;
}

const char*
fbd_feedback_profile_level_to_string (FbdFeedbackProfileLevel level)
{
  switch (level) {
  case FBD_FEEDBACK_PROFILE_LEVEL_SILENT:
    return "silent";
  case FBD_FEEDBACK_PROFILE_LEVEL_QUIET:
    return "quiet";
  case FBD_FEEDBACK_PROFILE_LEVEL_FULL:
    return "full";
  case FBD_FEEDBACK_PROFILE_LEVEL_UNKNOWN:
  default:
    return "full";
  }
}

/**
 * fbd_profile_update:
 * @self: The profile that should be updated
 * @new: The profile theme we want to take new feedbacks from
 *
 * Updates a profile. Feedbacks are read from the `new` profile. If
 * feedback already exists in `self` it is overwritten with the feedback
 * from `new`.
 *
 * It is not allowed to update a profile with a profile of a different name.
 */
void
fbd_feedback_profile_update (FbdFeedbackProfile *self, FbdFeedbackProfile *new)
{
  GHashTableIter iter;
  const char *event_name;
  FbdFeedbackBase *fb;

  g_return_if_fail (FBD_IS_FEEDBACK_PROFILE (self));
  g_return_if_fail (FBD_IS_FEEDBACK_PROFILE (new));

  g_return_if_fail (g_str_equal (fbd_feedback_profile_get_name (self),
                                 fbd_feedback_profile_get_name (new)));

  g_hash_table_iter_init (&iter, new->feedbacks);
  while (g_hash_table_iter_next (&iter, (gpointer)&event_name, (gpointer)&fb)) {
    g_hash_table_insert (self->feedbacks, g_strdup (event_name), g_object_ref (fb));
  }
}

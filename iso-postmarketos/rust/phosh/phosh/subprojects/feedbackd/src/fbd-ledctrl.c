/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-ledctrl"

#include <glib.h>

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define LED_BRIGHTNESS_ATTR      "brightness"
#define LED_MULTI_INTENSITY_ATTR "multi_intensity"
#define LED_PATTERN_ATTR         "pattern"
#define LED_REPEAT_ATTR          "repeat"
#define LED_TRIGGER_ATTR         "trigger"
#define LED_TRIGGER_PATTERN      "pattern"
#define LED_TRIGGER_HW_PATTERN   "hw_pattern"

enum {
  FBD_LEDCTRL_ERR_CMDLINE = 1,
  FBD_LEDCTRL_ERR_TRIGGER = 2,
  FBD_LEDCTRL_ERR_PERMS   = 3,
};

static gboolean
write_sysfs_attr (const char *sysfs_path, const char *attr, const char *val)
{
  gint fd;
  int len;
  g_autofree gchar *path = g_strjoin ("/", sysfs_path, attr, NULL);

  fd = open (path, O_WRONLY|O_TRUNC, 0666);
  if (fd < 0) {
    fprintf (stderr, "Failed to open %s: %s\n", path, strerror (errno));
    return FALSE;
  }

  len = strlen (val);
  if (write (fd, val, len) < 0) {
    fprintf (stderr, "Failed to write %s to %s: %s\n", val, path, strerror (errno));
    close (fd);
    return FALSE;
  }

  if (close (fd) < 0) {
    fprintf (stderr, "Failed to close %s: %s\n", path, strerror (errno));
    return FALSE;
  }

  return TRUE;
}

static gchar *
read_sysfs_attr (const char *sysfs_path, const char *attr)
{
  gchar *content = NULL;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *path = g_strjoin ("/", sysfs_path, attr, NULL);


  if (!g_file_get_contents (path, &content, NULL, &err)) {
    fprintf (stderr, "Failed to read %s: %s\n", path, err->message);
    return NULL;
  }
  
  return content;
}

static gboolean
set_sysfs_attr_perm (const char *sysfs_path, const char *attr, gid_t gid)
{
  g_autofree gchar *path = g_strjoin ("/", sysfs_path, attr, NULL);
  
  if (chown(path, -1, gid) < 0) {
    fprintf (stderr, "Failed to set perms of %s to %d: %s\n", path, gid, strerror (errno));
    return FALSE;
  }

  if (chmod(path, 0664) < 0) {
    fprintf (stderr, "Failed to set mode of %s: %s\n", path, strerror (errno));
    return FALSE;
  }
  
  return TRUE;
}

static gboolean
set_trigger (const char *sysfs_path, const char *trigger)
{
  g_autofree gchar *val = NULL;
  g_auto(GStrv) triggers = NULL;

  /*
   * Check the current trigger, don't do anything if it's already
   * set. This prevents a change event storm when setting the
   * same trigger over and over again in a udev rule.
   */
  val = read_sysfs_attr (sysfs_path, LED_TRIGGER_ATTR);
  g_strstrip(val);
  triggers = g_strsplit (val, " ", 0);

  /* 
   * The active trigger is marked with [...] so if we don't find the
   * trigger verbatim it's already the active one:
   */
  if (!g_strv_contains ((const gchar * const *)triggers, trigger))
    return TRUE;

  return write_sysfs_attr (sysfs_path, LED_TRIGGER_ATTR, trigger);
}

static gboolean
set_perms (const char *sysfs_path, const char *trigger, const char *gname)
{
  struct group *group;
  gboolean success = TRUE;

  group = getgrnam (gname);
  if (!group) {
    fprintf (stderr, "Failed to get group %s\n", gname);
    return FALSE;
  }

  if (!set_sysfs_attr_perm (sysfs_path, LED_BRIGHTNESS_ATTR, group->gr_gid))
      return FALSE;

  /* Attribute is optional */
  set_sysfs_attr_perm (sysfs_path, LED_MULTI_INTENSITY_ATTR, group->gr_gid);

  if (!g_strcmp0 (trigger, LED_TRIGGER_PATTERN)) {
    if (!set_sysfs_attr_perm (sysfs_path, LED_PATTERN_ATTR, group->gr_gid))
      success = FALSE;
    if (!set_sysfs_attr_perm (sysfs_path, LED_REPEAT_ATTR, group->gr_gid))
      success = FALSE;

    /* Attribute is optional */
    set_sysfs_attr_perm (sysfs_path, LED_TRIGGER_HW_PATTERN, group->gr_gid);
  }

  /* specific setup for other triggers goes here */
  return success;
}

int main(int argc, char *argv[])
{
  g_autoptr(GError) err = NULL;
  g_autoptr(GOptionContext) opt_context = NULL;
  g_autofree gchar *sysfs_path = NULL;
  g_autofree gchar *group = NULL;
  g_autofree gchar *trigger = NULL;

  const GOptionEntry options [] = {
    {"path", 'p', 0, G_OPTION_ARG_STRING, &sysfs_path,
     "Path to LEDs sysfs dir", NULL},
    {"group", 'G', 0, G_OPTION_ARG_STRING, &group,
     "Group to set permissions to", NULL},
    {"trigger", 't', 0, G_OPTION_ARG_STRING, &trigger,
     "LED trigger to configure", NULL},
    { NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL }
  };

  opt_context = g_option_context_new ("- helper to prepare sysfs for feedbackd");
  g_option_context_add_main_entries (opt_context, options, NULL);
  if (!g_option_context_parse (opt_context, &argc, &argv, &err)) {
    fprintf (stderr, "%s", err->message);
    g_clear_error (&err);
    return 1;
  }

  if (!sysfs_path) {
    fprintf (stderr, "No sysfs path given\n");
    return FBD_LEDCTRL_ERR_CMDLINE;
  }

  if (!trigger) {
    fprintf (stderr, "No trigger specified\n");
    return FBD_LEDCTRL_ERR_CMDLINE;;
  }
  g_debug ("Configuring LED at %s for trigger %s", sysfs_path, trigger);

  if (!set_trigger (sysfs_path, trigger))
    return FBD_LEDCTRL_ERR_TRIGGER;

  if (group) {
    g_debug ("Setting permission of %s to %s", sysfs_path, group);
    if (!set_perms (sysfs_path, trigger, group))
      return FBD_LEDCTRL_ERR_PERMS;
  }
    
  return 0;
}

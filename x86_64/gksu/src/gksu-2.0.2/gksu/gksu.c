#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <pwd.h>
#include <string.h>
#include <getopt.h>
#include <locale.h>

#include <glib.h>
#include <glib/gstdio.h>

#include <X11/Xlib.h>
#include <gtk/gtk.h>

#include <libgksu.h>

#include "defines.h"
#include "../config.h"

#define BASE_PATH "/apps/gksu/"

/* GLOBALS */
gboolean print_pass = FALSE;
gboolean force_grab = FALSE;
gboolean prompt = FALSE;
enum
  {
    SUDO_MODE,
    SU_MODE,
    DEFAULT_MODE
  };

struct option long_opts[] = {
    /*
     * { name  has_arg  *flag  val }
     */
    {"help", no_argument, NULL, 'h'},
    {"login", no_argument, NULL, 'l'},
    {"preserv-env", no_argument, NULL, 'k'},
    {"preserve-env", no_argument, NULL, 'k'},
    {"user", required_argument, NULL, 'u'},
    {"print-pass", no_argument, NULL, 'p'},
    {"message", required_argument, NULL, 'm'},
    {"title", required_argument, NULL, 't'},
    {"icon", required_argument, NULL, 'i'},
    {"disable-grab", optional_argument, NULL, 'g'},
    {"ssh-fwd", no_argument, NULL, 's'},
    {"debug", no_argument, NULL, 'd'},
    {"sudo-mode", no_argument, NULL, 'S'},
    {"su-mode", no_argument, NULL, 'w'},
    {"prompt", optional_argument, NULL, 'P'},
    {"desktop", required_argument, NULL, 'D'},
    {"description", required_argument, NULL, 'D'},
    {0, 0, 0, 0}
};

/**
 * help:
 * @cmdname:  name of the command which was called by the user
 * (argv[0])
 *
 * This function is a simple 'usage'-style printing function.
 * It is called if the user calls the program with --help or -h
 */
void
help (gchar *cmdname)
{
  gchar *help_trans;
  const gchar* help_text[] = {
    N_("GKsu version %s\n\n"),
    N_("Usage: %s [-u <user>] [options] <command>\n\n"),
    N_("  --debug, -d\n"
       "    Print information on the screen that might be\n"
       "    useful for diagnosing and/or solving problems.\n"),
    N_("\n"),
    N_("  --user <user>, -u <user>\n"
       "    Call <command> as the specified user.\n"),
    N_("\n"),
    N_("  --disable-grab, -g\n"
       "    Disable the \"locking\" of the keyboard, mouse,\n"
       "    and focus done by the program when asking for\n"
       "    password.\n"),
    N_("  --prompt, -P\n"
       "    Ask the user if they want to have their keyboard\n"
       "    and mouse grabbed before doing so.\n"),
    N_("  --preserve-env, -k\n"
       "    Preserve the current environments, does not set $HOME\n"
       "    nor $PATH, for example.\n"),
    N_("  --login, -l\n"
       "    Make this a login shell. Beware this may cause\n"
       "    problems with the Xauthority magic. Run xhost\n"
       "    to allow the target user to open windows on your\n"
       "    display!\n"),
    N_("\n"),
    N_("  --description <description|file>, -D <description|file>\n"
       "    Provide a descriptive name for the command to\n"
       "    be used in the default message, making it nicer.\n"
       "    You can also provide the absolute path for a\n"
       "    .desktop file. The Name key for will be used in\n"
       "    this case.\n"),
    N_("  --message <message>, -m <message>\n"
       "    Replace the standard message shown to ask for\n"
       "    password for the argument passed to the option.\n"
       "    Only use this if --description does not suffice.\n"),
    N_("\n"),
    N_("  --print-pass, -p\n"
       "    Ask gksu to print the password to stdout, just\n"
       "    like ssh-askpass. Useful to use in scripts with\n"
       "    programs that accept receiving the password on\n"
       "    stdin.\n"),
    N_("\n"),
    N_("  --sudo-mode, -S\n"
       "    Make GKSu use sudo instead of su, as if it had been\n"
       "    run as \"gksudo\".\n"),
    N_("  --su-mode, -w\n"
       "    Make GKSu use su, instead of using libgksu's\n"
       "    default.\n"),
  };

  help_trans = g_strconcat(_(help_text[0]), _(help_text[1]),
			   _(help_text[2]), _(help_text[3]),
			   _(help_text[4]), _(help_text[5]),
			   _(help_text[6]), _(help_text[7]),
			   _(help_text[8]), _(help_text[9]),
			   _(help_text[10]), _(help_text[11]),
			   _(help_text[12]), _(help_text[13]),
			   _(help_text[14]), _(help_text[15]),
			   NULL);
  g_print (_(help_trans), PACKAGE_VERSION, cmdname);
  g_free (help_trans);
}

static void
gk_dialog (GtkMessageType type, gchar *format, ...)
{
  GtkWidget *diag_win;

  va_list ap;
  gchar *msg;

  va_start(ap, format);
  msg = g_strdup_vprintf(format, ap);
  va_end(ap);

  diag_win = gtk_message_dialog_new_with_markup (NULL, GTK_DIALOG_MODAL,
						 type, GTK_BUTTONS_CLOSE,
						 "%s", msg);

  gtk_signal_connect_object (GTK_OBJECT(diag_win), "delete_event",
			     GTK_SIGNAL_FUNC(gtk_main_quit),
			     NULL);
  gtk_window_set_position (GTK_WINDOW(diag_win), GTK_WIN_POS_CENTER);
  gtk_window_set_resizable (GTK_WINDOW(diag_win), FALSE);

  gtk_widget_show_all (diag_win);
  gtk_dialog_run (GTK_DIALOG(diag_win));

  g_free (msg);

  gtk_widget_destroy (diag_win);
}

void
set_description_from_desktop (GksuContext *context, gchar *file_name)
{
  GKeyFile *desktop;
  GError *error = NULL;
  gchar *buffer = NULL;

  desktop = g_key_file_new ();

  g_key_file_load_from_file (desktop, file_name, G_KEY_FILE_NONE, &error);
  if (error)
    {
      gchar *error_msg;

      error_msg = g_strdup_printf ("Could not load desktop file: %s",
				   error->message);
      g_warning ("%s", error_msg);
      g_free (error_msg);
      g_error_free (error);
      g_key_file_free (desktop);
      return;
    }

  buffer = g_key_file_get_locale_string (desktop, "Desktop Entry",
					 "Name", NULL, NULL);
  if (buffer)
    {
      gksu_context_set_description (context, buffer);
      g_free (buffer);
    }

  g_key_file_free (desktop);
}

/* gksuexec */
void
response_ok_cb (GtkWidget *w, gpointer data)
{
  GtkWidget *dialog = (GtkWidget*)data;

  gtk_dialog_response (GTK_DIALOG(dialog),
		       GTK_RESPONSE_OK);
}

void
show_hide_advanced (GtkWidget *button, gpointer data)
{
  GtkWidget *parent, *tmp;

  GtkWidget *dialog;
  GtkWidget *vbox;
  GtkWidget *label;
  GtkWidget *check_login;
  GtkWidget *check_presenv;

  GksuContext *context = (GksuContext*)data;
  gint response;

  parent = gtk_widget_get_parent (button);
  while ((tmp = gtk_widget_get_parent (parent)) != NULL)
    parent = tmp;

  dialog = gtk_dialog_new_with_buttons (_("Advanced options"),
					GTK_WINDOW(parent),
					GTK_DIALOG_MODAL,
					GTK_STOCK_CLOSE,
					GTK_RESPONSE_CLOSE,
					NULL);
  gtk_dialog_set_has_separator (GTK_DIALOG(dialog), FALSE);
  gtk_container_set_border_width (GTK_CONTAINER(dialog), 4);

  /* vbox points to the dialog's vbox */
  vbox = GTK_DIALOG(dialog)->vbox;
  gtk_box_set_spacing (GTK_BOX(vbox), 3);

  /* label */
  label = gtk_label_new ("");
  gtk_label_set_markup (GTK_LABEL(label),
			_("<b>Options to use when changing user</b>"));
  gtk_box_pack_start (GTK_BOX(vbox), label, TRUE, TRUE, 5);
  gtk_widget_show (label);

  /* login shell? (--login) */
  check_login = gtk_check_button_new_with_mnemonic (_("_login shell"));
  if (gksu_context_get_login_shell (context) == TRUE) /* window may have been opened before */
    gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON(check_login), TRUE);
  gtk_box_pack_start (GTK_BOX(vbox), check_login, TRUE, TRUE, 0);
  gtk_widget_show (check_login);

  /* preserve environment (--preserve-env) */
  check_presenv =
    gtk_check_button_new_with_mnemonic (_("_preserve environment"));
  if (gksu_context_get_keep_env (context) == TRUE)
    gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON(check_presenv), TRUE);
  gtk_box_pack_start (GTK_BOX(vbox), check_presenv, TRUE, TRUE, 0);
  gtk_widget_show (check_presenv);

  response = gtk_dialog_run (GTK_DIALOG(dialog));

  if (response == GTK_RESPONSE_NONE)
    return;

  if (gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON(check_login)))
    gksu_context_set_login_shell (context, TRUE);
  else
    gksu_context_set_login_shell (context, FALSE);

  if (gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON(check_presenv)))
    gksu_context_set_keep_env (context, TRUE);
  else
    gksu_context_set_keep_env (context, FALSE);

  gtk_widget_destroy (dialog);
}

typedef struct {
  char *username;
  uid_t userid;
} TmpUser;

/*
 * Comparison function for g_list_sort()
 */
static int fill_with_user_list_cmp(gconstpointer a, gconstpointer b)
{
  return strcmp(((TmpUser *) a)->username, ((TmpUser *) b)->username);
}

/*
 * Fill combobox with an alphabetically sorted list of all users on the system
 */
static void
fill_with_user_list(GtkWidget *combobox)
{
  GList *tmp = NULL, *list;
  TmpUser *tu;
  struct passwd *pw;

  setpwent();

  /* Get all the users info and store it temporary */
  while ((pw = getpwent())) {
    tu = g_new(TmpUser, 1);

    tu->username = g_strdup(pw->pw_name);
    tu->userid = pw->pw_uid;

    tmp = g_list_prepend(tmp, tu);
  }

  /* Sort it! */
  tmp = g_list_sort(tmp, fill_with_user_list_cmp);

  /* Add only the usernames */
  for (list = tmp; list; list = g_list_next(list)) {
    tu = list->data;

    gtk_combo_box_append_text (GTK_COMBO_BOX(combobox), tu->username);

    if (!strcmp (tu->username, "root"))
      gtk_combo_box_set_active (GTK_COMBO_BOX(combobox),
				g_list_position(tmp, list));

    g_free(tu);
  }

  g_list_free(tmp);
  endpwent();
}

void
request_command_and_user (GksuContext *context)
{
  GtkWidget *dialog;
  GtkWidget *hbox;
  GtkWidget *lvbox;
  GtkWidget *rvbox;
  GtkWidget *image;

  GtkWidget *label_cmd;
  GtkWidget *entry_cmd;

  GtkWidget *label_user;
  GtkWidget *combo_user;

  /* advanced stuff */
  GtkWidget *advanced_button;

  gint response;

  gchar *tmp = NULL;

  dialog = gtk_dialog_new_with_buttons (_("Run program"), NULL, 0,
					GTK_STOCK_CANCEL,
					GTK_RESPONSE_CANCEL,
					GTK_STOCK_OK,
					GTK_RESPONSE_OK,
					NULL);
  gtk_dialog_set_has_separator (GTK_DIALOG(dialog), FALSE);

  /* horizontal box */
  hbox = gtk_hbox_new (FALSE, 4);
  gtk_container_set_border_width (GTK_CONTAINER(hbox), 5);
  gtk_box_pack_start (GTK_BOX(GTK_DIALOG(dialog)->vbox),
		      hbox, TRUE, TRUE, 2);

  /* left vertical box */
  lvbox = gtk_vbox_new (FALSE, 2);
  gtk_box_pack_start (GTK_BOX(hbox), lvbox, TRUE, TRUE, 0);

  /* command */
  label_cmd = gtk_label_new (_("Run:"));
  gtk_label_set_justify (GTK_LABEL(label_cmd), GTK_JUSTIFY_LEFT);
  gtk_box_pack_start (GTK_BOX(lvbox), label_cmd, TRUE, TRUE, 0);

  entry_cmd = gtk_entry_new ();
  gtk_signal_connect (GTK_OBJECT(entry_cmd), "activate",
		      GTK_SIGNAL_FUNC(response_ok_cb),
		      dialog);
  gtk_box_pack_start (GTK_BOX(lvbox), entry_cmd, TRUE, TRUE, 0);

  /* user name */
  label_user = gtk_label_new (_("As user:"));
  gtk_label_set_justify (GTK_LABEL(label_user), GTK_JUSTIFY_LEFT);
  gtk_box_pack_start (GTK_BOX(lvbox), label_user, TRUE, TRUE, 0);
  combo_user = gtk_combo_box_new_text ();
  fill_with_user_list (combo_user);

  gtk_box_pack_start (GTK_BOX(lvbox), combo_user, TRUE, TRUE, 0);

  /* right vertical box */
  rvbox = gtk_vbox_new (FALSE, 2);
  gtk_box_pack_start (GTK_BOX(hbox), rvbox, TRUE, TRUE, 0);

  /* image */
  image = gtk_image_new_from_file (DATA_DIR"/pixmaps/gksu-icon.png");
  gtk_box_pack_start (GTK_BOX(rvbox), image, TRUE, TRUE, 0);

  /* advanced button */
  advanced_button = gtk_button_new_with_mnemonic (_("_Advanced"));
  g_signal_connect (G_OBJECT(advanced_button), "clicked",
		    G_CALLBACK(show_hide_advanced), context);
  gtk_box_pack_start (GTK_BOX(rvbox), advanced_button, TRUE, FALSE, 0);

  /* let the magic begin! */
  gtk_widget_show_all (dialog);

  while (TRUE)
    {
      response = gtk_dialog_run (GTK_DIALOG(dialog));

      switch (response)
	{
	case GTK_RESPONSE_CANCEL:
	case GTK_RESPONSE_DELETE_EVENT:
	case GTK_RESPONSE_NONE:
	  exit (0);
	}

      tmp = gtk_editable_get_chars (GTK_EDITABLE(entry_cmd), 0, -1);
      if (tmp)
	{
	  gksu_context_set_command (context, tmp);
	  g_free (tmp);
	}

      tmp = gtk_combo_box_get_active_text (GTK_COMBO_BOX(combo_user));
      if (tmp)
	{
	  gksu_context_set_user (context, tmp);
	  g_free (tmp);
	}

      if (!strcmp (gksu_context_get_user (context), ""))
	{
	  gk_dialog (GTK_MESSAGE_ERROR, _("Missing command to run."));
	}
      else
	{
	  gtk_widget_destroy (dialog);
	  break;
	}
    }
}
/* gksuexec */

int
main (int argc, char **argv)
{
  GksuContext *context;

  GError *error = NULL;

  gint newargc = 0;
  gchar **newargv = NULL;
  gint8 exit_status = -1;

  guint run_mode = DEFAULT_MODE;

  int c = 0;

  setlocale (LC_ALL, "");
  bindtextdomain(PACKAGE_NAME, LOCALEDIR);
  bind_textdomain_codeset (PACKAGE_NAME, "UTF-8");
  textdomain(PACKAGE_NAME);

  /*
   * bad, bad code... adds a second -- right after the first one,
   * because gtk_init will remove one of them...
   */
  {
    /* to check whether a -- was already found when parsing arguments */
    gboolean separator_found = 0;

    for (c = 0; c < argc; c++)
      {
	if (!strcmp ("--", argv[c]) && (!separator_found))
	  {
	    newargv = g_realloc (newargv, sizeof(char*) * (newargc + 2));
	    newargv[newargc] = g_strdup (argv[c]);
	    newargv[newargc + 1] = g_strdup (argv[c]);

	    newargc = newargc + 2;
	    separator_found = TRUE;
	  }
	else
	  {
	    newargv = g_realloc (newargv, sizeof(char*) * (newargc + 1));
	    newargv[newargc] = g_strdup (argv[c]);

	    newargc++;
	  }
      }
  }

  gtk_init (&newargc, &newargv);

  context = gksu_context_new ();
  while ((c = getopt_long(newargc, newargv, "?hu:lpm:kt:i:gdsSwP::aD:", long_opts, NULL))
	 != EOF)
    {
      switch (c)
	{
	case 0:
	  break;

	case 'h':
	  help (newargv[0]);
	  exit(0);
	  break;
	case '?':
	  help (newargv[0]);
	  exit(0);
	  break;
	case 'u':
	  gksu_context_set_user (context, optarg);
	  break;
	case 'l':
	  gksu_context_set_login_shell (context, TRUE);
	  break;
	case 'p':
	  print_pass = TRUE;
	  break;
	case 'm':
	  gksu_context_set_message (context, optarg);
	  break;
	case 'k':
	  gksu_context_set_keep_env (context, TRUE);
	  break;
	case 'g':
	  gksu_context_set_grab (context, FALSE);

	  if (optarg != NULL)
	    {
	      if (!strcasecmp (optarg, "yes")); /* ignore, already set */
	      else if (!strcasecmp (optarg, "no"))
		gksu_context_set_grab (context, FALSE);
	      else
		{
		  fprintf (stderr, _("Option not accepted for --disable-grab: %s\n"),
			   optarg);
		  return 1;
		}
	    }

	  break;
	case 'd':
	  gksu_context_set_debug (context, TRUE);
	  break;
	case 'D':
	  if (!g_access (optarg, R_OK))
	    set_description_from_desktop (context, optarg);
	  else
	    gksu_context_set_description (context, optarg);
	  break;
	case 'S':
	  run_mode = SUDO_MODE;
	  break;
	case 'w':
	  run_mode = SU_MODE;
	  break;
	case 'P':
	  prompt = TRUE;

	  if (optarg != NULL)
	    {
	      if (!strcasecmp (optarg, "yes")); /* ignore, already set */
	      else if (!strcasecmp (optarg, "no"))
		prompt = FALSE;
	      else
		{
		  fprintf (stderr, _("Option not accepted for --prompt: %s\n"),
			   optarg);
		  return 1;
		}
	    }

	  break;
	}
    }

  { /* support gksu_sudo_run */
    gchar *myname = g_path_get_basename (argv[0]);
    if (!strcmp(myname, "gksudo"))
      run_mode = SUDO_MODE;
    g_free (myname);
  }

  if (force_grab)
    gksu_context_set_grab (context, TRUE);

  if (prompt)
    {
      GtkWidget *d;

      d = gtk_message_dialog_new_with_markup (NULL, 0, GTK_MESSAGE_QUESTION,
					      GTK_BUTTONS_YES_NO,
					      _("<b>Would you like your screen to be \"grabbed\"\n"
						"while you enter the password?</b>"
						"\n\n"
						"This means all applications will be paused to avoid\n"
						"the eavesdropping of your password by a a malicious\n"
						"application while you type it."));

      if (gtk_dialog_run (GTK_DIALOG(d)) == GTK_RESPONSE_NO)
	gksu_context_set_grab (context, FALSE);
      else
	gksu_context_set_grab (context, TRUE);

      gtk_widget_destroy (d);
    }

  if (print_pass)
    {
      gchar *password = NULL;

      if ((gksu_context_get_message (context) == NULL) &&
	  (gksu_context_get_description (context) == NULL) &&
	  (gksu_context_get_command (context) == NULL))
	{
	  gk_dialog (GTK_MESSAGE_ERROR,
		     _("<big><b>Missing options or arguments</b></big>\n\n"
		       "You need to provide --description or --message."));
	  return 1;
	}

      password = gksu_ask_password_full (context, NULL, &error);

      if (error)
	{
	  gk_dialog (GTK_MESSAGE_ERROR,
		     _("<b>Failed to request password.</b>\n\n%s"),
		     error->message);
	  return 3;
	}

      if (password)
	printf ("%s\n", password);

      return 0;
    }

  /* now we can begin to care about a command */
  if (newargc <= optind)
    request_command_and_user (context); /* previously known as gksuexec */
  else
    {
      gchar *command = g_strdup (newargv[optind]);
      gchar *tmp = NULL;
      gint i = 0;

      if (!strncmp ("--", command, 2))
	{
	  optind = optind + 1;

	  if (newargc <= optind)
	    {
	      gk_dialog (GTK_MESSAGE_ERROR, _("Missing command to run."));
	      return 1;
	    }

	  g_free (command);
	  command = g_strdup (newargv[optind]);
	}

      for (i = optind + 1; i < newargc; i++)
	{
	   // in sudo mode, check for ' and \ in string and escape it
	  if(run_mode == SUDO_MODE && 
	     (strchr(newargv[i],'\'') || strchr(newargv[i],'\\'))) 
	       {
		  const gchar *p = newargv[i];
		  gchar *q,*dest;
		  dest = q = g_malloc(strlen(newargv[i])*2+1);
		  while(*p) {
		     if (*p == '\'')
			*q++ = '\\';
		     else if (*p == '\\')
			*q++ = '\\';
		     *q++ = *p++;
		  }
		  *q = 0;
		  g_free(newargv[i]);
		  newargv[i] = dest;
	       }
	  tmp = g_strconcat (command, " '", newargv[i], "'", NULL);
	  g_free (command);
	  command = tmp;
	}
      gksu_context_set_command (context, command);
      g_free (command);
    }

  /*
   * FIXME: should be moved to libgksu, which should have two new API functions:
   * gksu_context_launcher_context_{initiate,complete}
   */

  {
    struct passwd *pwentry;

    pwentry = getpwnam (gksu_context_get_user (context));

    if (!pwentry)
      {
	gk_dialog (GTK_MESSAGE_ERROR, _("User %s does not exist."),
		   gksu_context_get_user (context));
	return 1;
      }

    if (pwentry->pw_uid == geteuid ())
      {
	gint retval = g_spawn_command_line_sync (gksu_context_get_command (context),
						 NULL, NULL, NULL, NULL);
	return retval;
      }
  }

  {
    gint count = 0;

    for (count = 0; count < 3; count++)
      {
	if (error) /* wrong password was given */
	  {
	    gksu_context_set_alert (context, _("<b>Incorrect password... try again.</b>"));
	    g_error_free (error);
	    error = NULL;
	  }

	if (run_mode == SUDO_MODE)
	  gksu_sudo_fuller (context,
			    NULL, NULL,
			    NULL, NULL,
			    &exit_status,
			    &error);
	else if (run_mode == SU_MODE)
	  gksu_su_fuller (context,
			  NULL, NULL,
			  NULL, NULL,
			  &exit_status,
			  &error);

	else
	  gksu_run_fuller (context,
			   NULL, NULL,
			   NULL, NULL,
			   &exit_status,
			   &error);
	if ((error == NULL) || (error->code != GKSU_ERROR_WRONGPASS))
	  break;
      }
  }

  if (error && (error->code != GKSU_ERROR_CANCELED))
    {
      gk_dialog (GTK_MESSAGE_ERROR,
		 _("<b>Failed to run %s as user %s.</b>\n\n%s"),
		 gksu_context_get_command (context),
		 gksu_context_get_user (context),
		 error->message);
      return 3;
    }

  return exit_status;
}

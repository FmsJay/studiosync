// A place in REAPER's menus for a script-based tool: Extensions > <Name> and View > <Name>, plus one action, "<Name>: open", that runs the
// tool's own script (found in the Actions list by its file name: a script's command id differs per computer and per run). The menu item is
// ticked while the tool's window is open (its script's toggle). Shared by StudioSync and ReaPersona; build with -DREAPERSONA for ReaPersona.
// And, when the tool's settings ask for it (ExtState <SECTION> "toolbar button" = "1"), a button for it at the end of REAPER's main toolbar,
// with its own image (toolbar_<name>.png in REAPER's Data/toolbar_icons, put there by the tool): added each time REAPER builds the default
// toolbar, as Helgobox adds Playtime's (James, 0.58.81), so it comes and goes with the setting, not by editing the toolbar.
// REAPER's ReaScript API has no way to add menu items, and editing reaper-menu.ini replaces the whole menu (hiding what SWS and ReaPack add).
// GPL-3.0-or-later, as the tools it opens.
#ifdef _WIN32
#include <windows.h>
#endif // (macOS, Linux: reaper_plugin.h brings SWELL, ../WDL/swell/swell.h beside the SDK folder; REAPER supplies it through swell-modstub)
#include <cstdio>
#include <cstring>

#define REAPERAPI_IMPLEMENT
#define REAPERAPI_MINIMAL
#define REAPERAPI_WANT_AddExtensionsMainMenu
#define REAPERAPI_WANT_kbd_enumerateActions
#define REAPERAPI_WANT_SectionFromUniqueID
#define REAPERAPI_WANT_Main_OnCommand
#define REAPERAPI_WANT_GetToggleCommandState
#define REAPERAPI_WANT_ShowMessageBox
#define REAPERAPI_WANT_GetExtState
#define REAPERAPI_WANT_SetExtState
#define EXT_VERSION "1.0.2" // (tools/make_index.py EXT_VERSION: what the panel reads to know this build adds toolbar buttons)
#include "reaper_plugin.h"
#include "reaper_plugin_functions.h"

#ifdef REAPERSONA
static const char *NAME = "ReaPersona", *SCRIPT = "ReaPersona.lua", *CMD = "REAPERSONA_OPEN", *DESC = "ReaPersona: open";
static const char *SECTION = "ReaPersona", *ICON = "toolbar_reapersona";
#else
static const char *NAME = "StudioSync", *SCRIPT = "StudioSync - Panel.lua", *CMD = "STUDIOSYNC_OPEN", *DESC = "StudioSync: open the panel";
static const char *SECTION = "BandSync", *ICON = "toolbar_studiosync"; // (StudioSync's settings section kept its first name)
#endif

static int g_cmd = 0, g_target = 0;
static gaccel_register_t g_accel = { { 0, 0, 0 }, nullptr };

// The script's action: an entry in the main section named "<anything>: <SCRIPT>" ("Script: ..." from ReaPack, "Custom: ..." otherwise). -> 0 if none.
static int find_target()
{
  KbdSectionInfo *sec = SectionFromUniqueID(0);
  const size_t sl = strlen(SCRIPT);
  for (int i = 0;; i++) {
    const char *name = nullptr;
    const int cmd = kbd_enumerateActions(sec, i, &name);
    if (!cmd) break;
    if (!name) continue;
    const size_t n = strlen(name);
    if (n >= sl + 2 && !strcmp(name + n - sl, SCRIPT) && name[n - sl - 1] == ' ' && name[n - sl - 2] == ':') return cmd;
  }
  return 0;
}

static bool on_command(int command, int flag)
{
  if (!command || command != g_cmd) return false;
  if (!g_target) g_target = find_target(); // (once found it stays: a script keeps its command id for the session)
  if (g_target) Main_OnCommand(g_target, 0);
  else {
    char msg[300];
    snprintf(msg, sizeof(msg), "%s isn't installed yet (its script %s isn't in the Actions list).\n\n"
             "Extensions > ReaPack > Synchronize packages, then try again.", NAME, SCRIPT);
    ShowMessageBox(msg, NAME, 0);
  }
  return true;
}

static int on_toggle(int command)
{
  if (command != g_cmd) return -1;
  if (!g_target) return 0;
  return GetToggleCommandState(g_target) == 1 ? 1 : 0;
}

// The menu's last item: one of these tools (the other extension got there first, and brought the separator), or a separator already?
static bool after_ours_or_line(HMENU menu)
{
  const int n = GetMenuItemCount(menu);
  if (n <= 0) return true;
  char text[64] = "";
  MENUITEMINFO mi = {};
  mi.cbSize = sizeof(mi);
  mi.fMask = MIIM_TYPE;
  mi.dwTypeData = text;
  mi.cch = sizeof(text);
  if (!GetMenuItemInfo(menu, n - 1, TRUE, &mi)) return false;
  return (mi.fType & MFT_SEPARATOR) || !strcmp(text, "StudioSync") || !strcmp(text, "ReaPersona");
}

static void add_item(HMENU menu, bool separator)
{
  MENUITEMINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (separator && !after_ours_or_line(menu)) {
    mi.fMask = MIIM_TYPE;
    mi.fType = MFT_SEPARATOR;
    InsertMenuItem(menu, GetMenuItemCount(menu), TRUE, &mi);
  }
  mi.fMask = MIIM_TYPE | MIIM_ID;
  mi.fType = MFT_STRING;
  mi.dwTypeData = (char *)NAME;
  mi.wID = g_cmd;
  InsertMenuItem(menu, GetMenuItemCount(menu), TRUE, &mi);
}

static bool toolbar_wanted()
{
  const char *v = GetExtState(SECTION, "toolbar button");
  return v && !strcmp(v, "1");
}

// Only while the default menu is being built (flag 0): a menu someone customized keeps exactly what they put in it.
static void on_menu(const char *id, HMENU menu, int flag)
{
  if (flag != 0 || !g_cmd || !id || !menu) return;
  if (!strcmp(id, "Main extensions")) add_item(menu, false);
  else if (!strcmp(id, "Main view")) add_item(menu, true);
  else if (!strcmp(id, "Main toolbar") && toolbar_wanted()) {
    MENUITEMINFO mi = {};
    mi.cbSize = sizeof(mi);
    mi.fMask = MIIM_TYPE | MIIM_ID;
    mi.fType = MFT_STRING;
    mi.dwTypeData = (char *)NAME;
    mi.wID = g_cmd;
    InsertMenuItem(menu, GetMenuItemCount(menu), TRUE, &mi);
  }
}

// The button's image, wherever the command sits on a toolbar (REAPER asks per toolbar, command and state).
static const char *on_icon(const char *toolbar, int cmd, int state)
{
  if (cmd == g_cmd && toolbar && (!strcmp(toolbar, "Main toolbar") || !strncmp(toolbar, "Floating toolbar", 16))) return ICON;
  return nullptr;
}

extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
  if (!rec) return 0; // (unloading: nothing to free)
  if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc || REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;
  g_cmd = rec->Register("command_id", (void *)CMD);
  if (!g_cmd) return 0;
  g_accel.desc = DESC;
  g_accel.accel.cmd = (WORD)g_cmd;
  rec->Register("gaccel", &g_accel);
  rec->Register("hookcommand", (void *)on_command);
  rec->Register("toggleaction", (void *)on_toggle);
  rec->Register("hookcustommenu", (void *)on_menu);
  rec->Register("toolbar_icon_map", (void *)on_icon);
  SetExtState(SECTION, "menu extension", EXT_VERSION, false);
  AddExtensionsMainMenu();
  return 1;
}

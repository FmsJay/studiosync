// A place in REAPER's menus for a script-based tool: Extensions > <Name> and View > <Name>, plus one action, "<Name>: open", that runs the
// tool's own script (found in the Actions list by its file name: a script's command id differs per computer and per run). The menu item is
// ticked while the tool's window is open (its script's toggle). Shared by StudioSync and ReaPersona; build with -DREAPERSONA for ReaPersona.
// And, when the tool's settings ask for it (ExtState <SECTION> "toolbar button" = "1"), a button for it at the end of REAPER's main toolbar,
// with its own image (toolbar_<name>.png in REAPER's Data/toolbar_icons, put there by the tool). Added through REAPER's own
// AddCustomMenuOrToolbarItem (7.11 on; not in the SDK header, nor open to scripts: the signatures are reaper-rs's bindings, MIT), which works
// on a toolbar someone customized too and isn't saved into it, as Helgobox adds Playtime's: checked a second after REAPER starts and whenever
// the setting changes, so it comes and goes with the setting. (1.0.2 added it only while REAPER built the default toolbar, and James's
// toolbar was customized by then: it never showed. 0.58.83)
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
#define REAPERAPI_WANT_RefreshToolbar2
#define EXT_VERSION "1.0.12" // (tools/make_index.py EXT_VERSION: what the panel reads to know this build adds toolbar buttons; 1.0.7: the direct link; 1.0.8: its messages, clock, streams, audio spike; 1.0.9: signed updates, extension/sign.cpp; 1.0.10: streams in 64 KB frames, StudioSync_DirectFileTime, a stream's read errors in DirectStreams; 1.0.11: a growing take's size asked every way, StudioSync_DirectTrace, a WAV copy's header held back until its first whole frame; 1.0.12: stream frames in flight, send anything, link speed per peer)
#ifndef REAPERSONA
#include "direct.h" // (the direct link: extension/direct.cpp. James, 0.59.50; before reaper_plugin.h: SWELL's min/max macros broke its C++ headers on Linux)
#include "webui.h" // (the web UI server: extension/webui.cpp. James, rt)
#include "webui_dock.h" // (the web UI docked in REAPER: extension/webui_dock.cpp. James, rt)
#endif
#include "reaper_plugin.h"
#include "reaper_plugin_functions.h"

#ifdef REAPERSONA
static const char *NAME = "ReaPersona", *SCRIPT = "ReaPersona.lua", *CMD = "REAPERSONA_OPEN", *DESC = "ReaPersona: open";
static const char *SECTION = "ReaPersona", *ICON = "toolbar_reapersona", *ICON_FILE = "toolbar_reapersona.png";
#else
static const char *NAME = "StudioSync", *SCRIPT = "StudioSync - Panel.lua", *CMD = "STUDIOSYNC_OPEN", *DESC = "StudioSync"; // (James, 0.58.87: just "StudioSync", it was "StudioSync: open the panel")
static const char *SECTION = "BandSync", *ICON = "toolbar_studiosync", *ICON_FILE = "toolbar_studiosync.png"; // (StudioSync's settings section kept its first name)
#endif

static int g_cmd = 0, g_target = 0;
#ifndef REAPERSONA
// An amber dot on the button while something has stopped syncing (ExtState "sync problem", which StudioSync - Autostart sets and clears), so
// it's seen with the panel closed: toolbar_studiosync_warn(_on).png beside the others. (1.0.6, StudioSync 0.59.10)
static const char *ICON_WARN = "toolbar_studiosync_warn";
static int g_warn = -1;
static bool warn_now() { const char *v = GetExtState(SECTION, "sync problem"); return v && *v; }
#endif
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
}

// The toolbar button. Last extra_flags: 0 refreshes the toolbar now, 1 doesn't. Get's command out: > 0 a command, -1 a separator.
typedef bool (*AddItemFn)(const char *menu, int pos, int command, int toolbarflags, const char *label, const char *iconfn, int extra_flags);
typedef bool (*DeleteItemFn)(const char *menu, int pos, int extra_flags);
typedef bool (*GetItemFn)(const char *menu, int pos, int *command, int *toolbarflags, const char **label, const char **iconfn);
static AddItemFn g_add_item;
static DeleteItemFn g_delete_item;
static GetItemFn g_get_item;
static int g_shown = -1; // what the toolbar has been made to match: -1 not looked yet, 0 no button wanted, 1 wanted
static bool g_added = false; // the button there is the one this extension added (one put there by hand stays when the setting goes off)
static int g_ticks = 0;
static const char *TOOLBAR = "Main toolbar";

// Where the button is on the main toolbar (-1: not there), and how many items it has; `old_label`: whether it's labelled other than DESC.
static int find_button(int *count, bool *old_label, int *old_flags)
{
  int at = -1, i = 0;
  for (;; i++) {
    int cmd = 0, flags = 0;
    const char *label = nullptr, *icon = nullptr;
    if (!g_get_item(TOOLBAR, i, &cmd, &flags, &label, &icon)) break;
    if (cmd == g_cmd && at < 0) { at = i; *old_label = label && strcmp(label, DESC) != 0; *old_flags = flags; }
    if (i > 500) break; // (a guard: no toolbar is that long)
  }
  *count = i;
  return at;
}

// REAPER's timer (about 30 times a second). The button lit while the tool's window is open, however it was opened: the script's action is
// looked for here, not only on a click (opened from its own action or at start, the button stayed dark: James, 0.58.83), and the toolbar is
// told when that changes, about 6 times a second. The button itself, about once a second.
static int g_lit = -1, g_look = 0, g_search = 0;
static void on_timer()
{
  if (++g_look >= 5) {
    g_look = 0;
    if (!g_target && g_search++ % 30 == 0) g_target = find_target(); // (every 5 s until found: it reads the whole Actions list)
    const int lit = on_toggle(g_cmd);
    if (lit != g_lit) { g_lit = lit; RefreshToolbar2(0, g_cmd); }
#ifndef REAPERSONA
    const int warn = warn_now() ? 1 : 0;
    if (warn != g_warn) { g_warn = warn; RefreshToolbar2(0, g_cmd); }
#endif
  }
  if (!g_add_item || !g_delete_item || !g_get_item || ++g_ticks < 30) return;
  g_ticks = 0;
  const int want = toolbar_wanted() ? 1 : 0;
  if (want == g_shown) return;
  int count = 0, flags = 0;
  bool old_label = false;
  const int at = find_button(&count, &old_label, &flags);
  if (want && at < 0) g_added = g_add_item(TOOLBAR, count, g_cmd, 0, DESC, ICON_FILE, 0);
  // (a button put there under an older name, "StudioSync: open the panel" by hand: the same place, today's name. James, 0.58.87)
  else if (want && old_label && g_delete_item(TOOLBAR, at, 1)) g_added = g_add_item(TOOLBAR, at, g_cmd, flags, DESC, ICON_FILE, 0);
  else if (!want && at >= 0 && g_added) { g_delete_item(TOOLBAR, at, 0); g_added = false; }
  g_shown = want;
}

// The button's image, wherever the command sits on a toolbar (REAPER asks per toolbar, command and state).
static const char *on_icon(const char *toolbar, int cmd, int state)
{
#ifndef REAPERSONA
  if (cmd == g_cmd && toolbar && (!strcmp(toolbar, "Main toolbar") || !strncmp(toolbar, "Floating toolbar", 16))) return g_warn == 1 ? ICON_WARN : ICON;
#else
  if (cmd == g_cmd && toolbar && (!strcmp(toolbar, "Main toolbar") || !strncmp(toolbar, "Floating toolbar", 16))) return ICON;
#endif
  return nullptr;
}

extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
  if (!rec) { // (unloading: the direct link's threads stop)
#ifndef REAPERSONA
    direct_audio_stop();
    webui_dock_shutdown(); // (its window and view, before the server they show)
    webui_shutdown(); // (first: it takes HTTP from the link's listener)
    direct_shutdown();
#endif
    return 0;
  }
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
  g_add_item = (AddItemFn)rec->GetFunc("AddCustomMenuOrToolbarItem");
  g_delete_item = (DeleteItemFn)rec->GetFunc("DeleteCustomMenuOrToolbarItem");
  g_get_item = (GetItemFn)rec->GetFunc("GetCustomMenuOrToolbarItem");
  const bool toolbar_api = g_add_item && g_delete_item && g_get_item;
  rec->Register("timer", (void *)on_timer);
#ifndef REAPERSONA
  direct_register(rec); // (reaper.StudioSync_Direct*: lib/direct.lua)
  direct_audio_register(rec); // (reaper.StudioSync_DirectAudio*: the step-4 spike, idle until started)
  webui_register(rec); // (reaper.StudioSync_WebUI*: lib/webui.lua; idle until Live sync or the panel starts it)
  webui_dock_register(rec); // ("StudioSync: Web UI (docked)" and reaper.StudioSync_WebUIDock)
  { void sign_register(reaper_plugin_info_t *); sign_register(rec); } // (reaper.StudioSync_Verify*, KeyCreate, Sign, FileHash: signed updates, extension/sign.cpp)
#endif
  SetExtState(SECTION, "menu extension", EXT_VERSION, false);
  SetExtState(SECTION, "menu extension toolbar", toolbar_api ? "1" : "0", false); // (REAPER before 7.11 has no way: the panel says so)
  AddExtensionsMainMenu();
  return 1;
}

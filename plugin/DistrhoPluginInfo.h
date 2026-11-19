// StudioSync Hop's description for DPF (plugin/third_party/DPF). GPL-3.0-or-later.
#ifndef DISTRHO_PLUGIN_INFO_H_INCLUDED
#define DISTRHO_PLUGIN_INFO_H_INCLUDED

#define DISTRHO_PLUGIN_BRAND "StudioSync"
#define DISTRHO_PLUGIN_NAME "StudioSync Hop"
#define DISTRHO_PLUGIN_URI "urn:studiosync:hop"
#define DISTRHO_PLUGIN_CLAP_ID "studiosync.hop"
#define DISTRHO_PLUGIN_LABEL "StudioSyncHop"
#define DISTRHO_PLUGIN_BRAND_ID SSyn
#define DISTRHO_PLUGIN_UNIQUE_ID SHop

#define DISTRHO_PLUGIN_HAS_UI 0 // (REAPER's own parameter view is enough, and no UI means no pugl/OpenGL to build)
#define DISTRHO_PLUGIN_IS_RT_SAFE 1
#define DISTRHO_PLUGIN_NUM_INPUTS 2
#define DISTRHO_PLUGIN_NUM_OUTPUTS 2
#define DISTRHO_PLUGIN_WANT_LATENCY 1
#define DISTRHO_PLUGIN_WANT_TIMEPOS 1 // (latency and hop id changes wait for the transport to stop: a PDC change mid-play can glitch)

#define DISTRHO_PLUGIN_VST3_CATEGORIES "Fx|Network|Stereo"
#define DISTRHO_PLUGIN_CLAP_FEATURES "audio-effect", "utility", "stereo"

#endif

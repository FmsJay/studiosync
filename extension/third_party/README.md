# Third-party code in the extension

Each section is one library: where it came from, its version and its licence. Sections are kept separate so branches
that each add a library merge cleanly.

## WebView2 SDK (the docked web UI on Windows: extension/webui_dock.cpp)

- **Source:** the `Microsoft.Web.WebView2` NuGet package from nuget.org only
  (https://www.nuget.org/packages/Microsoft.Web.WebView2), downloaded with James's OK (2026-11-19).
- **Version:** 1.0.4314.35 (stable). Package SHA-256:
  `90778deb1b77e36292828b4b5833c9255c27533f40e0ddd55891ae718944edc4`.
- **Licence:** Microsoft's BSD-style licence in `webview2/LICENSE.txt` (redistribution in source and binary form allowed with
  the notice kept; GPL-compatible). `webview2/NOTICE.txt` is the package's third-party notice, kept beside it.
- **What's kept** (only what the build needs, byte for byte from the package):
  - `webview2/include/WebView2.h` (from `build/native/include/`)
  - `webview2/x64/WebView2LoaderStatic.lib` (from `build/native/x64/`): the static loader, so there's no `WebView2Loader.dll`
    to ship beside the extension.
  - `webview2/LICENSE.txt`, `webview2/NOTICE.txt`
- **Not kept:** WebView2EnvironmentOptions.h, the WinRT interop files, the x86/arm64 loaders, WebView2Loader.dll, the .NET
  assemblies. Add them from the same package version if a later build needs them.
- **At run time** the pages are drawn by the Microsoft Edge WebView2 Runtime installed on the computer (Windows 11 has it;
  Windows 10 may not): the extension says so and offers the browser when it's missing.
- macOS uses the system's WKWebView (WebKit.framework) and Linux has no view yet (the browser instead), so neither needs
  anything from here.

# Third-party code in plugin/

## DPF (DISTRHO Plugin Framework)

- What: the framework StudioSync Hop is built on; it supplies the VST3 and CLAP wrappers (its own VST3 interface headers and the CLAP
  headers are included, so no Steinberg SDK is needed).
- Source: https://github.com/DISTRHO/DPF
- Version: commit `4238e1c7f0351bbe488d79f0899c540543ac7583` on `main` ("Merge branch 'develop'", 2025-10-23). DPF publishes no
  release tags, so the commit is the pin.
- Licence: ISC (`DPF/LICENSE`). Some optional parts carry their own licences (`DPF/LICENSING.md`); none of them are built here.
- What was kept: `distrho/`, `cmake/`, `utils/` (the macOS bundle templates and export lists CMake uses), `CMakeLists.txt`, `LICENSE`,
  `LICENSING.md`, `README.md`, `FEATURES.md`. Left out: `dgl/` and its pugl submodule (the Hop has no UI), `examples/`, `tests/`, `lac/`.
  No nested `.git`, no local changes.
- To update: fetch a newer commit, copy the same folders over, rebuild (`plugin/build_windows.cmd`, or CMake as in
  `.github/workflows/plugin.yml`), and record the commit here.

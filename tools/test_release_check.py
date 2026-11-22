"""tools/release_check.py on a tiny tree: a ready release passes; each way a release broke or could break is caught."""
import pathlib, shutil, sys, tempfile, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release_check  # noqa: E402
import sign_release  # noqa: E402

VER, EXT = "0.60.0", "1.0.38"


def index(versions, ext_versions):
    def src(tag, f, extra=""):
        return f'<source {extra}file="{f}">https://github.com/FmsJay/studiosync/raw/{tag}/{f}</source>'
    main = "".join(f'<version name="{v}">' + src(f"v{v}", "StudioSync - Live sync.lua", 'main="main" ') + src(f"v{v}", "lib/band.lua") + src(f"v{v}", "lib/tools.lua") +
                   "</version>" for v in versions)
    ext = "".join(f'<version name="{e}">' + "".join(src(tag, f"extension/{n}", f'platform="{p}" ') for n, p in release_check.EXT_FILES.items()) +
                  "</version>" for e, tag in ext_versions)
    return (f'<?xml version="1.0"?><index version="1"><category name="StudioSync"><reapack name="StudioSync.lua" type="script">{main}</reapack>'
            f'<reapack name="StudioSync menus.ext" type="extension">{ext}</reapack></category></index>')


class ReleaseCheck(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="rt-installer-release-"))
        r = self.root
        for d in ("lib", "tools", "extension"):
            (r / d).mkdir()
        (r / "StudioSync - Live sync.lua").write_text("-- live\n")
        (r / "lib" / "tools.lua").write_text(f'tools.EXT_WANT = "{EXT}"\n')
        self.version(VER)
        (r / "tools" / "make_index.py").write_text(f'EXT_VERSION = "{EXT}"\n')
        (r / "extension" / "reaper_menu.cpp").write_text(f'#define EXT_VERSION "{EXT}"\n')
        for n in release_check.EXT_FILES:
            (r / "extension" / n).write_bytes(b"x\0" + EXT.encode() + b"\0y")
        for d in release_check.HOP_DIRS:
            (r / "plugin" / "dist" / d / "StudioSync Hop.vst3").mkdir(parents=True)
            (r / "plugin" / "dist" / d / "StudioSync Hop.clap").write_bytes(b"clap")
        self.index(["0.59.49", VER], [("1.0.6", "v0.59.49"), (EXT, f"v{VER}")])
        self.tags = {"v0.59.49"}

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def version(self, v):
        (self.root / "lib" / "band.lua").write_text(f'local band = {{ VERSION = "{v}" }}\n')
        sign_release.write(self.root)  # (lib/files.txt as make_index writes it)

    def index(self, versions, ext_versions):
        (self.root / "index.xml").write_text(index(versions, ext_versions))

    def problems(self):
        return release_check.problems(self.root, self.tags)

    def test_ready(self):
        self.assertEqual(self.problems(), [])

    def test_missing_tag(self):  # (the realtime branch's 0.59.49.1 and extension 1.0.9 entries pointed at a tag never pushed)
        self.index(["0.59.49", "0.59.49.1", VER], [("1.0.6", "v0.59.49"), ("1.0.9", "v0.59.49.1"), (EXT, f"v{VER}")])
        p = self.problems()
        self.assertTrue(any("0.59.49.1 points at v0.59.49.1" in x for x in p), p)
        self.assertTrue(any("menus.ext 1.0.9 points at v0.59.49.1" in x for x in p), p)

    def test_test_build_version(self):
        self.version("0.59.49.98")
        self.index(["0.59.49", "0.59.49.98"], [("1.0.6", "v0.59.49"), (EXT, "v0.59.49.98")])
        self.assertTrue(any("four numbers" in x for x in self.problems()))

    def test_not_newer(self):
        self.index(["0.59.49", "0.61.0", VER], [("1.0.6", "v0.59.49"), (EXT, f"v{VER}")])
        self.tags.add("v0.61.0")
        self.assertTrue(any("isn't newer than 0.61.0" in x for x in self.problems()))

    def test_extension_mismatch(self):
        (self.root / "lib" / "tools.lua").write_text('tools.EXT_WANT = "1.0.39"\n')
        (self.root / "extension" / "reaper_studiosync.dylib").write_bytes(b"x\x001.0.37\0")
        p = self.problems()
        self.assertTrue(any("version disagrees" in x for x in p), p)
        self.assertTrue(any("reaper_studiosync.dylib isn't the 1.0.38 build" in x for x in p), p)

    def test_stale_files_and_hop(self):
        (self.root / "lib" / "new.lua").write_text("-- new\n")
        shutil.rmtree(self.root / "plugin" / "dist" / "mac")
        p = self.problems()
        self.assertTrue(any(x.startswith("lib/files.txt doesn't match") for x in p), p)
        self.assertTrue(any("plugin/dist/mac/StudioSync Hop.clap is missing" in x for x in p), p)

    def test_newer(self):
        self.assertTrue(release_check.newer("0.60.0", "0.59.49.97"))
        self.assertTrue(release_check.newer("0.59.49.1", "0.59.49"))
        self.assertFalse(release_check.newer("0.59.49", "0.59.49.0"))


if __name__ == "__main__":
    unittest.main()

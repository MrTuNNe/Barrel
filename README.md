# Barrel

Run Windows games and programs on your Mac. A maintained replacement for [Whisky](https://github.com/Whisky-App/Whisky).

> "Barrel" is a working title.

Barrel builds its own Wine and gets everything else from maintained projects:

| Part | Source | Used for |
|---|---|---|
| Barrel Wine (CrossOver sources, Wine 11) | built by this repo's CI, see below | the engine for games |
| Wine 10 (Sikarugir, based on CrossOver) | [Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines) | fallback engine |
| D3DMetal, DXMT, DXVK, KosmicKrisp Vulkan, GStreamer | [Sikarugir-App/Template](https://github.com/Sikarugir-App/Template) | DirectX on Metal, video, fonts |
| Wine Staging, latest (optional) | [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) | plain upstream Wine |

## Barrel Wine

`.github/workflows/wine.yml` runs every day. When CodeWeavers publishes a new [CrossOver open-source release](https://www.codeweavers.com/crossover/source), the workflow:

1. builds it on an Apple Silicon runner with `engine/build.sh`, applying the patches in `engine/patches`;
2. checks that a bottle starts, the fonts work and DXMT draws (runner VMs only have a paravirtual GPU, so D3DMetal and DXVK are tested on a real Mac);
3. publishes the result as a `wine-cx-<version>` release.

Barrel installs the newest of those releases (`barrel update`, or automatically in the app). The only patch so far adds `WINEDLLPATH_PREPEND`, so D3DMetal, DXMT and DXVK can replace Wine's own Direct3D DLLs. The build steps follow [pedrosimoess/wine-macos27-steam-build](https://github.com/pedrosimoess/wine-macos27-steam-build).

To build locally (about 6 GB of disk):

```bash
engine/build.sh 26.3.0
BARREL_ENGINE_TARBALL=dist/barrel-wine-26.3.0.tar.xz cli/barrel setup
```

## Requirements

- An Apple Silicon Mac with macOS 14 or later (macOS 15+ ships `jq`; on 14, `brew install jq`)
- Rosetta 2: `softwareupdate --install-rosetta`

## The app

```bash
./build.sh
open build/Barrel.app
```

Click **Install** the first time. It downloads about 250 MB. Then create a bottle with **+**. A bottle is a separate Windows install.

To run something, drop a `.exe` onto the bottle or click **Run…**. Installed programs show up in the list. Right-click a program to add it to `~/Applications`.

**Recent** lists what you launched lately with the renderer and HUD setting it ran with. ▶ runs it again with those settings. Barrel checks the file before every launch. If it's gone, or a shortcut's program was uninstalled, the entry says so and offers **Remove**. If you reinstall the program or plug the drive back in, it works again.

### Updates

The app checks GitHub once a day, and from **Barrel › Check for Barrel Updates…**. When a newer `vX.Y.Z` release is out, it offers to download it. To publish a version, push a tag; `.github/workflows/app.yml` builds the app and creates the release:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

## The command line

Everything the app does goes through `cli/barrel`, and you can use it directly:

```bash
cli/barrel setup
cli/barrel new games
cli/barrel run games ~/Downloads/SteamSetup.exe
cli/barrel set games renderer dxmt
cli/barrel tricks games vcrun2022
```

Run `cli/barrel` with no arguments for the full list.

## Graphics

| Renderer | DirectX | Notes |
|---|---|---|
| `d3dmetal` (default) | 11, 12 | Apple's Game Porting Toolkit layer, 64-bit only. 32-bit programs switch to DXMT automatically. |
| `dxmt` | 10, 11 | Metal, 32 and 64-bit |
| `dxvk` | 9, 10, 11 | Vulkan through KosmicKrisp |
| `wined3d` | 9 | OpenGL; macOS OpenGL is too old for DX11 |

DirectX 9 always works. With `d3dmetal` and `dxmt` it goes through wined3d.

## RPG Maker MV/MZ, NW.js and Electron games

Games made with NW.js (RPG Maker MV and MZ, and many other JavaScript games) ship a Windows build of NW.js, which rarely starts under Wine. Their game files run fine on the macOS build of NW.js. When you run such a game's `.exe`, Barrel spots it (`package.json` or `package.nw` next to `nw.dll`, `nw.pak`…) and starts it with NW.js for macOS. NW.js is downloaded the first time, about 175 MB.

Electron games work the same way. They have a `resources/app` (or `app.asar`) next to a `version` file, and Barrel runs them with the macOS build of that exact Electron version, downloaded once per version (about 100 MB). Games with Windows-only native modules (`.node` files) may still need Wine.

NW.js games keep their saves in the game's folder, as on Windows. To run a game through Wine anyway, turn off **Run JavaScript games natively** for the bottle (`barrel set <bottle> native off`). Games packed into a single `.exe` (Enigma Virtual Box) can't be spotted, so they still go through Wine.

## Fonts

Many engines, Unity among them, read font files straight from `C:\windows\Fonts` instead of asking Windows. If the files aren't there, the text is invisible. Like Proton, Barrel puts fonts in every bottle. It links the macOS fonts there, adds Windows file names (`arial.ttf`, `msgothic.ttc`, `simsun.ttc`, `malgun.ttf`…) and maps Windows font names to macOS ones (MS Gothic and Meiryo to Hiragino Sans, SimSun to Songti, Malgun Gothic to Apple SD Gothic Neo, Segoe UI to Helvetica Neue).

## Tests

`tests/run.sh` checks the fonts, then every renderer combination. It draws a triangle off-screen with Direct3D 9, 11 and 12, in 32-bit and 64-bit (`tests/gfxtest.cpp`), and checks the pixel colour. To build the test programs you need [llvm-mingw](https://github.com/mstorsjo/llvm-mingw):

```bash
x86_64-w64-mingw32-clang++ -O1 -o tests/gfxtest64.exe tests/gfxtest.cpp -static -ld3d9 -ld3d11 -ld3d12 -ldxgi -ld3dcompiler -luuid
i686-w64-mingw32-clang++ -O1 -o tests/gfxtest32.exe tests/gfxtest.cpp -static -ld3d9 -ld3d11 -ld3d12 -ldxgi -ld3dcompiler -luuid
x86_64-w64-mingw32-clang++ -O1 -o tests/fonttest.exe tests/fonttest.cpp -static -lgdi32
```

## Where files live

- `~/Library/Application Support/Barrel/engines`: Wine engines
- `~/Library/Application Support/Barrel/runtime`: libraries and graphics layers
- `~/Library/Application Support/Barrel/bottles/<name>`: each bottle. `barrel.conf` holds its settings and `barrel.log` its output.

## Known limits

- Sikarugir's Wine 11 engines only start inside the Sikarugir app, so Barrel skips them; its fallback is their Wine 10. The `staging` engine is upstream Wine but only has wined3d.
- Games with kernel-level anti-cheat (Valorant, Fortnite and many online shooters) don't run under any Wine.

## License

Barrel is MIT licensed (see [LICENSE](LICENSE)). It downloads Wine, D3DMetal, DXMT, DXVK and the other components at install time and doesn't redistribute them. Each keeps its own license: Wine is LGPL, and D3DMetal falls under Apple's Game Porting Toolkit license.

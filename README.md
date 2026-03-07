# Sikarugir / MacWineRunner
A wrapper project that's the successor to Wineskin — and home of **MacWineRunner**, an open-source CrossOver clone for macOS (Intel + Apple Silicon M-series).\
This project supports *macOS 10.15.4* or later. MacWineRunner requires *macOS 13 Ventura* or later.

<br>

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/gcenx)
[![](https://dcbadge.limes.pink/api/server/hD48GFpWz5?compact=true)](https://discord.gg/NTrT4QUvVS)

<br>

> [!NOTE]
> How to install using [homebrew](https://brew.sh/)
> ```
> brew upgrade
> brew install --cask Sikarugir-App/sikarugir/sikarugir
> ```
>
> Apple Silicon systems also require Rosetta2
> ```
> /usr/sbin/softwareupdate --install-rosetta --agree-to-license
> ```
> 
<br>

[![How to Play PC Games on Mac with SIKARUGIR – Step-by-Step Guide](/images/IMG_0921.png)](http://www.youtube.com/watch?v=pCgYxRPIqjE&t=23s)


<br>

> [!IMPORTANT]
> DirectX support
> - WineD3D (default) Supports DirectX 11 and below.
> - VKD3D (default) Limited DirectX 12 support.
> - D3DMetal (toggle) 64Bit Direct3D 11 & 12 via Metal (Apple Silicon Macs).
> - DXMT (toggle) DirectX 10 & DirectX 11 via Metal.
> - DXVK (toggle) DirectX 10 & 11 via Vulkan.
> - D9VK (winetricks) DirectX 9 via Vulkan (experimental and no longer being developed).
>
> <br>
>
> Apples D3DMetal commonly refered to as GPTK is closed source and has a restrictive license\
> it can not be used for commerial ports, that's not the case for all over renders.\
> You can review the license for [D3DMetal-v3.0](/D3DMetal/3.0/License.pdf)

<br>

> [!CAUTION]
> My Antivirus says it's a VIRUS!!!\
> You need to contact your Antivirus/Anti-malware vendor to report these as false positives.\
> This started once wine moved to using *Mingw-gcc* to compile PE binaries.
> 
> __See the following examples:__
> - [CrossOver 19 and antivirus programs](https://www.codeweavers.com/support/forums/general/?t=27;msg=222870)
> - [Windows Defender detects Occamy.c trojan in steam proton 5.0 folder](https://github.com/ValveSoftware/Proton/issues/3593)

<br>

---

## MacWineRunner

MacWineRunner is a native Swift + SwiftUI GUI tool for running Windows applications and games on macOS — both Intel and Apple Silicon (M-series). It lives in the `MacWineRunner/` folder of this repository.

### Requirements

| | Minimum |
|---|---|
| macOS | 13 Ventura |
| Xcode | 15+ (or Swift 5.9 toolchain) |
| Apple Silicon | Rosetta 2 recommended for x86_64 Wine engines |

### Build from source

```bash
# Clone the repo
git clone https://github.com/Sikarugir-App/Sikarugir.git
cd Sikarugir/MacWineRunner

# Build (debug)
swift build

# Build release
swift build -c release

# Run directly
swift run MacWineRunner
```

Or open `MacWineRunner/Package.swift` in Xcode and press **Run**.

### Architecture

```
MacWineRunner/
├── Package.swift
└── Sources/MacWineRunner/
    ├── App/                  Entry point (@main)
    ├── Models/               Bottle, WineEngine, GraphicsBackend
    ├── Services/             SystemDetector, BottleManager, WineManager,
    │                         EngineDownloader, ProcessRunner
    └── Views/                ContentView, BottleListView, BottleDetailView,
                              InstallWizardView, EngineManagerView, SettingsView
```

### Supported Graphics Backends

| Backend | DirectX | Platform | Notes |
|---|---|---|---|
| D3DMetal (GPTK) | D3D 11 & 12 | Apple Silicon + macOS 14+ | Closed-source, restrictive license |
| DXMT | D3D 10 & 11 | macOS 14+ | Metal-native |
| DXVK | D3D 9/10/11 | macOS 13+ | Via MoltenVK / Vulkan |
| VKD3D-Proton | D3D 12 | macOS 13+ | Via MoltenVK / Vulkan |
| WineD3D | D3D ≤ 11 | macOS 13+ | Built-in software renderer |

### First-time setup

1. Launch MacWineRunner.
2. Go to **Engines** → download a Wine engine (e.g. *Staging 9.21*).
3. Go to **Bottles** → press **⇧⌘N** to create a new bottle, picking your engine and backend.
4. In the bottle detail, press **Install App…** and select your `.exe` or `.msi` installer.

---

## Components that fall under LGPL-2.1 license
- `Configure.app` (modified version of  `Wineskin.app`)

Sources can be found https://github.com/Sikarugir-App/Sikarugir-foss-sources

<br>

## Components that don't fall under LGPL-2.1 license
_master wrappers Template-1.0/Wineskin-3.0.6-1 or greater_
- `Sikarugir Launcher` (Running in wineskin compatibility mode)
- `Creator.app` (v1.0.1 or greater)

<br>

## Credits
- [VitorMM](https://github.com/vitor251093) for modernizing the [Wineskin Codebase](https://github.com/vitor251093/wineskin) & [ObjectiveC_Extension](https://github.com/vitor251093/ObjectiveC_Extension) & writting Sikarugir-App from the ground up.
- [PaulTheTall](https://www.paulthetall.com/) for constant test data and finding bugs.
- doh123 for creating [Wineskin](https://web.archive.org/web/20141218081028/http://wineskin.urgesoftware.com/tiki-index.php).
- [Gcenx](https://github.com/Gcenx) for maintaining the Wine Engines & upstream Winehq packages.

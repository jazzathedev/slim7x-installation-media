# Windows 11 ARM64 Bootable USB - Lenovo Yoga Slim 7X

Creates a bootable Windows 11 ARM64 USB installer for the Lenovo Yoga Slim 7X (Snapdragon X Elite).

Rufus doesn't work on this laptop (hangs on the YOGA logo). This script does the whole process automatically.

## Usage

1. Plug in a USB drive (any size - a 14 GB FAT32 partition will be created on it)
2. Open PowerShell as Administrator
3. Run:
   ```
   C:\path\to\make-usb.ps1
   ```
4. Follow the prompts

The script will:
- Download the Windows 11 ARM64 ISO from Microsoft (~6 GB)
- Create a 14 GB FAT32 partition on the USB (Windows refuses FAT32 >32 GB, hence the smaller partition)
- Copy all installer files to the USB
- Split `install.wim` into chunks that fit FAT32's 4 GB file size limit
- Optionally write an `autounattend.xml` with Rufus-style tweaks (see below)
- Download the Qualcomm FastConnect 7800 WiFi driver to the USB root

Re-running the script is safe - it skips steps that are already done.

## Unattended tweaks (optional)

When prompted, type `YES` to add `autounattend.xml` to the USB. This gives you:

| Tweak | Effect |
|---|---|
| `BypassNRO` | "I don't have internet" button appears on the network screen |
| `HideOnlineAccountScreens` | Skips Microsoft account screen, forces local account (Pro only) |
| `HideEULAPage` | Auto-accepts EULA |
| `HideWirelessSetupInOOBE` | Skips wifi screen (no driver installed yet anyway) |
| Telemetry policy | Set to Security-only (minimum) |
| Advertising ID | Disabled |
| Cortana | Disabled |

## After installing

Windows won't have WiFi drivers out of the box. At the "connect to internet" screen:

1. Press `Shift+F10` to open a command prompt
2. Run `explorer` to browse files
3. If the USB has no drive letter, assign one with `diskpart` → `list volume` → `select volume X` → `assign letter=F`
4. Run `wifi-driver.exe` from the USB root
5. Once connected, Windows automatically downloads all remaining drivers (including Lenovo-specific hotkeys etc.)

The only thing that doesn't auto-install is X-Rite Color Assistant - get that from Lenovo's support site if you want it.

## Why not Rufus / Lenovo's tool?

- **Rufus**: The USB shows in the boot menu but selecting it hangs on the YOGA logo forever
- **Lenovo Recovery Media Creator**: Works, but installs Lenovo's customised image rather than stock Windows

#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a bootable Windows 11 ARM64 USB for Lenovo Yoga Slim 7X
.DESCRIPTION
    Downloads the Windows 11 ARM64 ISO from Microsoft, formats E: to FAT32,
    makes it bootable with bootsect, copies all files, and splits install.wim
    so it fits within FAT32's 4 GB file size limit.

    Run as Administrator (the script will self-elevate if needed).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# === Config ===
$WorkDir  = "C:\Users\jazza\Downloads\yoga"
$IsoPath  = "$WorkDir\Win11_ARM64.iso"
$SzExe    = "C:\Program Files\7-Zip\7z.exe"
$UsbDrive = "E:"
$UsbLabel = "WIN11ARM"

# === Self-elevate ===
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching as Administrator..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  OK: $msg"   -ForegroundColor Green }
function Err($msg)  { Write-Host "  !! $msg"    -ForegroundColor Red; throw $msg }

# === Step 1: Download ISO ===
Step "Windows 11 ARM64 ISO"
if (Test-Path $IsoPath) {
    Ok "ISO already present: $IsoPath"
} else {
    Write-Host "  Attempting download via Microsoft Software Download API..." -ForegroundColor Yellow

    try {
        # Microsoft's download API (same flow as Rufus/Fido)
        $Arch      = "ARM64"
        $SessionId = [System.Guid]::NewGuid().ToString()
        $Headers   = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; ARM64; rv:109.0) Gecko/20100101 Firefox/115.0" }

        # Register session
        Invoke-WebRequest -UseBasicParsing -SessionVariable MsSession `
            "https://vlscppe.microsoft.com/fp/tags?org_id=y6jn8c31&session_id=$SessionId" | Out-Null

        # Get SKU list for Windows 11 ARM64 (product edition ID 2618)
        $SkuUrl = "https://www.microsoft.com/en-us/api/controls/contentinclude/html" +
                  "?pageId=a8f8f489-4c7f-463a-9ca6-5cff94d8d041" +
                  "&host=www.microsoft.com" +
                  "&segments=software-download,windows11arm64" +
                  "&query=&action=getskuinformationbyproductedition" +
                  "&sessionId=$SessionId" +
                  "&productEditionId=2618" +
                  "&SKU=0"

        $SkuHtml = (Invoke-WebRequest -UseBasicParsing -WebSession $MsSession -Headers $Headers $SkuUrl).Content
        # Extract first skuId value
        if ($SkuHtml -match '"Id":(\d+)') {
            $SkuId = $Matches[1]
            Ok "SKU ID: $SkuId"
        } else {
            throw "Could not parse SKU ID from Microsoft API response"
        }

        # Get download links
        $DlUrl = "https://www.microsoft.com/en-us/api/controls/contentinclude/html" +
                 "?pageId=6e2a1789-ef16-4f27-a296-74ef7ef5d96b" +
                 "&host=www.microsoft.com" +
                 "&segments=software-download,windows11arm64" +
                 "&query=&action=GetProductDownloadLinksBySku" +
                 "&sessionId=$SessionId" +
                 "&skuId=$SkuId"

        $DlHtml = (Invoke-WebRequest -UseBasicParsing -WebSession $MsSession -Headers $Headers $DlUrl).Content

        # Extract the ISO URL (ARM64)
        if ($DlHtml -match 'href="(https://[^"]+arm64[^"]+\.iso)"') {
            $IsoUrl = $Matches[1]
            Ok "Found ISO URL"
        } elseif ($DlHtml -match 'href="(https://[^"]+\.iso)"') {
            $IsoUrl = $Matches[1]
            Ok "Found ISO URL (fallback match)"
        } else {
            throw "Could not find ISO download URL in API response"
        }

        Write-Host "  Downloading (~6 GB, this will take a while)..." -ForegroundColor Yellow
        Write-Host "  URL: $IsoUrl" -ForegroundColor DarkGray

        # Use BITS for resumable download with progress
        Import-Module BitsTransfer
        Start-BitsTransfer -Source $IsoUrl -Destination $IsoPath -DisplayName "Windows 11 ARM64 ISO" -Description "Downloading..."
        Ok "ISO downloaded to $IsoPath"

    } catch {
        Write-Host "`n  Auto-download failed: $_" -ForegroundColor Red
        Write-Host @"

  Please download the Windows 11 ARM64 ISO manually:
    1. Go to: https://www.microsoft.com/en-us/software-download/windows11arm64
    2. Download the ISO (~6 GB)
    3. Save it as: $IsoPath
    4. Then re-run this script.

"@ -ForegroundColor Yellow
        exit 1
    }
}

# === Step 2: Format E: as FAT32 ===
Step "Format USB drive ($UsbDrive) as FAT32"

$UsbLetter = $UsbDrive.TrimEnd(':')
$vol = Get-Volume -DriveLetter $UsbLetter -ErrorAction SilentlyContinue

if ($vol -and $vol.FileSystem -eq 'FAT32') {
    Ok "Already FAT32 - skipping format"
} else {
    Write-Host "  WARNING: This will ERASE all data on $UsbDrive" -ForegroundColor Red
    $confirm = Read-Host "  Type YES to continue"
    if ($confirm -ne "YES") { Write-Host "Aborted."; exit 0 }

    # Windows built-in tools (diskpart format, Format-Volume, format.com) all refuse
    # FAT32 on partitions > 32 GB. Solution: create a 14 GB partition - more than
    # enough for the installer files (~8 GB with split WIM) and within the FAT32 limit.
    $diskNum = (Get-Disk | Where-Object { $_.Path -like "*USBSTOR*" -or $_.BusType -eq "USB" } |
                Sort-Object Number | Select-Object -Last 1).Number
    if ($null -eq $diskNum) {
        # Fallback: look for disk 3 (known from earlier inspection)
        $diskNum = (Get-Partition -DriveLetter $UsbLetter -ErrorAction SilentlyContinue).DiskNumber
    }
    if ($null -eq $diskNum) { Err "Could not determine USB disk number" }
    Write-Host "  USB is Disk $diskNum - creating 14 GB FAT32 partition..." -ForegroundColor Yellow

    @(
        "select disk $diskNum",
        "clean",
        "create partition primary size=14000",
        "select partition 1",
        "format fs=fat32 quick label=$UsbLabel",
        "assign letter=$UsbLetter",
        "active",
        "exit"
    ) -join "`n" | diskpart

    Start-Sleep -Seconds 3   # let Windows register the new volume

    # Verify
    $vol = Get-Volume -DriveLetter $UsbLetter -ErrorAction SilentlyContinue
    if (-not $vol -or $vol.FileSystem -ne 'FAT32') {
        Err "Format failed - E: is still not FAT32 (FileSystem: $($vol.FileSystem))"
    }
    Ok "Drive formatted as FAT32 (14 GB partition)"
}

# Partition is already marked active by the format step above (UEFI boots from
# EFI\BOOT\BOOTAA64.EFI on the FAT32 partition - no bootsect needed)

# === Step 5: Copy all ISO files EXCEPT sources\install.wim ===
Step "Copy ISO contents to USB (excluding install.wim)"
$MountDir = "$WorkDir\iso_mount"

# Skip extraction if already done (efi folder is a reliable sentinel)
if (Test-Path "$MountDir\efi") {
    Ok "iso_mount already populated - skipping re-extraction"
} else {
    if (Test-Path $MountDir) { Remove-Item $MountDir -Recurse -Force }
    New-Item -ItemType Directory $MountDir | Out-Null
    Write-Host "  Extracting ISO with 7-zip..." -ForegroundColor Yellow
    & $SzExe x -y "-o$MountDir" $IsoPath "-x!sources\install.wim" | Out-Null
    Ok "ISO extracted (without install.wim)"
}

Write-Host "  Copying to USB..." -ForegroundColor Yellow
robocopy $MountDir "$UsbDrive\" /E /NFL /NDL /NJH /NJS | Out-Null
Ok "Files copied to USB"

# === Step 6: Split install.wim ===
Step "Extract and split install.wim (4000 MB chunks)"
$WimSrc  = "$WorkDir\install.wim"
$SwmDest = "$WorkDir\install.swm"

if (-not (Test-Path $WimSrc)) {
    Write-Host "  Extracting install.wim from ISO (~4-5 GB)..." -ForegroundColor Yellow
    & $SzExe e -y "-o$WorkDir" $IsoPath "sources\install.wim" | Out-Null
}
if (-not (Test-Path $WimSrc)) { Err "install.wim not found after extraction" }
Ok "install.wim extracted"

Write-Host "  Splitting with DISM..." -ForegroundColor Yellow
if (Test-Path $SwmDest) { Remove-Item "$WorkDir\install*.swm" -Force }
$dism = Start-Process -FilePath "dism.exe" `
    -ArgumentList "/Split-Image /ImageFile:`"$WimSrc`" /SWMFile:`"$SwmDest`" /FileSize:4000" `
    -Wait -PassThru -NoNewWindow
if ($dism.ExitCode -ne 0) { Err "DISM split failed (exit $($dism.ExitCode))" }
Ok "install.wim split into .swm files"

# === Step 7: Copy .swm files to USB ===
Step "Copy .swm files to USB sources folder"
$SwmFiles = Get-Item "$WorkDir\install*.swm"
foreach ($f in $SwmFiles) {
    Copy-Item $f.FullName "$UsbDrive\sources\" -Force
    Ok "Copied $($f.Name)"
}

# === Step 8: Download WiFi driver (Qualcomm FastConnect 7800 ARM64) ===
Step "WiFi driver for post-install"
$WifiDriverDest = "$UsbDrive\wifi-driver.exe"
if (-not (Test-Path $WifiDriverDest)) {
    Write-Host "  Downloading Qualcomm FastConnect 7800 WiFi driver from Dell..." -ForegroundColor Yellow
    # Dell driver 75JHH - Qualcomm FastConnect 7800, WINARM64, v1.0.4135.200
    $WifiUrl = "https://dl.dell.com/FOLDER12256259M/3/Qualcomm-FastConnect-7800-Wi-Fi-and-Bluetooth-Driver_75JHH_WINARM64_1.0.4135.200_A02.EXE"
    try {
        Import-Module BitsTransfer
        Start-BitsTransfer -Source $WifiUrl -Destination $WifiDriverDest
        Ok "WiFi driver saved to USB root"
    } catch {
        Write-Host "  WiFi driver download failed ($_)" -ForegroundColor Yellow
        Write-Host "  Get it manually from Dell: search 'Qualcomm FastConnect 7800 ARM64 driver'" -ForegroundColor Yellow
    }
}

# === Step 9: Rufus-style autounattend.xml (optional) ===
Step "Unattended setup tweaks (optional)"
Write-Host "  Add autounattend.xml to skip EULA, force local account," -ForegroundColor Yellow
Write-Host "  bypass internet requirement, and disable telemetry?" -ForegroundColor Yellow
$addUnattend = Read-Host "  Type YES to add it"
if ($addUnattend -eq "YES") {
    $unattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <!-- "I don't have internet" button in OOBE -->
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <!-- Telemetry: Security only (minimum) -->
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection /v AllowTelemetry /t REG_DWORD /d 0 /f</Path>
        </RunSynchronousCommand>
        <!-- Disable advertising ID -->
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo /v Enabled /t REG_DWORD /d 0 /f</Path>
        </RunSynchronousCommand>
        <!-- Disable tips / suggested content -->
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent /v DisableSoftLanding /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <!-- Disable Cortana -->
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 0 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <!-- Force local account path (Pro only) -->
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <!-- Skip wifi screen - no driver installed yet -->
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <!-- Don't auto-enable recommended privacy settings -->
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
'@
    Set-Content -Path "$UsbDrive\autounattend.xml" -Value $unattendXml -Encoding UTF8
    Ok "autounattend.xml written to USB root"
} else {
    Write-Host "  Skipped." -ForegroundColor DarkGray
}

# === Done ===
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  USB drive is ready!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host @"

Next steps:
  1. Plug the USB into your Yoga Slim 7X
  2. Power on while holding F12
  3. Select the USB from the boot menu
  4. Install Windows 11 as normal

After installing, if WiFi is missing:
  - Press Shift+F10 at the 'connect to internet' screen to open cmd
  - Run: explorer (to browse the USB)
  - If USB has no drive letter, use diskpart to assign one
  - Run wifi-driver.exe from the USB root
  - Once WiFi works, Windows will auto-download all other drivers

"@ -ForegroundColor White

# Converts LVGL .bin icons to C arrays and writes lv_img_dsc_t wrappers
# Usage: Run from repo root with PowerShell: powershell -NoProfile -ExecutionPolicy Bypass -File tools/convert_battery_bin.ps1

$ErrorActionPreference = 'Stop'

function Write-IconCFile {
    param(
        [Parameter(Mandatory=$true)][string]$Name,            # lv_img symbol name
        [Parameter(Mandatory=$true)][string]$BinPath,        # source .bin path
        [Parameter(Mandatory=$true)][string]$OutPath         # destination .c path
    )

    if (-not (Test-Path -LiteralPath $BinPath)) {
        throw "Missing bin: $BinPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($BinPath)
    
    # Extract size from filename (e.g., "64dp" -> 64x64)
    # Google Material Icons use square icons with size in filename
    if ($Name -match '_(\d+)dp_') {
        $size = [int]$Matches[1]
        $width = $size
        $height = $size
    } else {
        # Fallback: try parsing LVGL header (may not work for all formats)
        $width = 64
        $height = 64
    }
    
    # Parse color format from first byte
    $cf = $bytes[0]
    
    # Determine color format constant
    $cfName = "LV_IMG_CF_RAW"
    if ($cf -eq 0x04) { $cfName = "LV_IMG_CF_TRUE_COLOR" }
    elseif ($cf -eq 0x05) { $cfName = "LV_IMG_CF_TRUE_COLOR_ALPHA" }
    elseif ($cf -eq 0x06) { $cfName = "LV_IMG_CF_TRUE_COLOR_CHROMA_KEYED" }
    elseif ($cf -eq 0x07) { $cfName = "LV_IMG_CF_INDEXED_1BIT" }
    elseif ($cf -eq 0x08) { $cfName = "LV_IMG_CF_INDEXED_2BIT" }
    elseif ($cf -eq 0x09) { $cfName = "LV_IMG_CF_INDEXED_4BIT" }
    elseif ($cf -eq 0x0A) { $cfName = "LV_IMG_CF_INDEXED_8BIT" }
    elseif ($cf -eq 0x0B) { $cfName = "LV_IMG_CF_ALPHA_1BIT" }
    elseif ($cf -eq 0x0C) { $cfName = "LV_IMG_CF_ALPHA_2BIT" }
    elseif ($cf -eq 0x0D) { $cfName = "LV_IMG_CF_ALPHA_4BIT" }
    elseif ($cf -eq 0x0E) { $cfName = "LV_IMG_CF_ALPHA_8BIT" }
    
    # If ALPHA_8BIT, strip 4-byte header and set proper LVGL descriptor (best quality for recolor)
    $payload = $bytes
    if ($cf -eq 0x0E -and $bytes.Length -ge 4) {
        $cfName = "LV_IMG_CF_ALPHA_8BIT"
        $payload = $bytes[4..($bytes.Length - 1)]
    }

    # Format bytes as C hex list, 16 per line
    $hex = for ($i = 0; $i -lt $payload.Length; $i++) { '0x{0:X2}' -f $payload[$i] }
    $lines = @()
    for ($i = 0; $i -lt $hex.Count; $i += 16) {
        $end = [Math]::Min($i + 15, $hex.Count - 1)
        $slice = $hex[$i..$end] -join ','
        $lines += "  $slice,"
    }

    $c = @()
    $c += "#include <lvgl.h>"
    $c += ""
    $c += "static const uint8_t ${Name}_bin[] = {"
    $c += $lines
    $c += "};"
    $c += ""
    $c += "const lv_img_dsc_t $Name={.header={.always_zero=0,.w=$width,.h=$height,.cf=$cfName},.data_size=sizeof(${Name}_bin),.data=${Name}_bin};"
    $c += ""

    $dir = Split-Path -Parent $OutPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [System.IO.File]::WriteAllLines($OutPath, $c)
    Write-Host "WROTE: $OutPath  (size=$($bytes.Length), ${width}x${height}, cf=0x$($cf.ToString('X2')))"
}

$root = Split-Path -Parent $PSScriptRoot

$map = @(
    @{ Name='battery_android_alert_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_alert_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_alert.c' },
    @{ Name='battery_android_bolt_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_bolt_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_bolt.c' },
    @{ Name='battery_android_frame_1_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_frame_1_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_1.c' },
    @{ Name='battery_android_frame_2_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_frame_2_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_2.c' },
    @{ Name='battery_android_frame_3_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_frame_3_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_3.c' },
    @{ Name='battery_android_frame_4_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_frame_4_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_4.c' },
    @{ Name='battery_android_frame_5_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_frame_5_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_5.c' },
    @{ Name='battery_android_frame_6_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_frame_6_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_6.c' },
    @{ Name='battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40'; Bin='C:\Users\harry\Downloads\battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40.bin'; Out='firmware/m5stack/src/icon_battery_full.c' }
)

foreach ($m in $map) {
    $outFull = Join-Path $root $m.Out
    Write-IconCFile -Name $m.Name -BinPath $m.Bin -OutPath $outFull
}


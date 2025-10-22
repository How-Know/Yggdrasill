Param(
  [Parameter(Mandatory=$true)] [string]$In,
  [Parameter(Mandatory=$true)] [string]$Out,
  [Parameter(Mandatory=$true)] [string]$SymName,
  [int]$Width = 64,
  [int]$Height = 64
)

if (!(Test-Path -LiteralPath $In)) {
  Write-Error "Input file not found: $In"; exit 1
}

$bytes = [System.IO.File]::ReadAllBytes($In)
$sb = New-Object System.Text.StringBuilder

[void]$sb.AppendLine('#include <lvgl.h>')
[void]$sb.AppendLine()
[void]$sb.AppendLine("const uint8_t $SymName`_map[]={")

for ($i = 0; $i -lt $bytes.Length; $i += 16) {
  $end = [Math]::Min($i + 15, $bytes.Length - 1)
  $slice = $bytes[$i..$end]
  $line = ($slice | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','
  if ($end -lt ($bytes.Length - 1)) { $line += ',' }
  [void]$sb.AppendLine("  $line")
}

[void]$sb.AppendLine('};')
[void]$sb.AppendLine()
[void]$sb.AppendLine("const lv_img_dsc_t $SymName={.header={.always_zero=0,.w=$Width,.h=$Height,.cf=LV_IMG_CF_TRUE_COLOR_ALPHA},.data_size=$($bytes.Length),.data=$SymName`_map};")

$dir = [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $Out))
if (!(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$sb.ToString() | Out-File -LiteralPath $Out -Encoding ASCII -Force
Write-Host "Generated: $Out ($($bytes.Length) bytes)"



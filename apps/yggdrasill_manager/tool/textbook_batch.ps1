# Runs tool/textbook_batch.dart (see the header there for the steps).
#   .\tool\textbook_batch.ps1 login                 # asks for the email, sends a sign-in code, then asks for it
#   .\tool\textbook_batch.ps1 preview [-Only 1-1/0-0]
#   .\tool\textbook_batch.ps1 dismiss -Only 1-2/0-0 -Crops <crop id>[,<crop id>]
#   .\tool\textbook_batch.ps1 render -Only 1-2/0-0/W2
#   .\tool\textbook_batch.ps1 answer -Only 1-1/3-1 -Crops <crop id> -Value '@C:\path\answer.txt'
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('login', 'status', 'preview', 'consistency', 'meta', 'dismiss', 'render', 'snapshot', 'answer', 'recrop',
    'pb_figure_width', 'reconfirm', 'logout')]
  [string]$Step,
  [string]$Only = '',
  [string]$Email = '',
  [string]$Crops = '',
  [string]$Value = ''
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
# The render step opens the textbook PDFs with pdfium.dll and pdfrx.dll from the Windows build.
$env:PATH = "$(Join-Path (Get-Location) 'build\windows\x64\runner\Debug');$env:PATH"

function Invoke-Batch([string]$BatchStep, [string[]]$Defines) {
  $flutterArgs = @('test', 'tool/textbook_batch.dart', '-r', 'expanded', "--dart-define=BATCH_STEP=$BatchStep")
  if ($Only) { $flutterArgs += "--dart-define=BATCH_ONLY=$Only" }
  foreach ($d in $Defines) { $flutterArgs += "--dart-define=$d" }
  & flutter @flutterArgs
  if ($LASTEXITCODE -ne 0) { throw "textbook_batch $BatchStep failed" }
}

if ($Step -eq 'login') {
  while (-not $Email.Trim()) { $Email = Read-Host 'Email' }
  # Build the list with += only: a one-item array returned from an if-expression unrolls to a string.
  $defines = @()
  $defines += "BATCH_EMAIL=$($Email.Trim())"
  Invoke-Batch 'send_otp' $defines
  $code = ''
  while (-not $code.Trim()) { $code = Read-Host 'Code from the email' }
  $defines += "BATCH_OTP=$($code.Trim())"
  Invoke-Batch 'verify_otp' $defines
} else {
  $defines = @()
  if ($Crops) { $defines += "BATCH_CROPS=$Crops" }
  if ($Value) { $defines += "BATCH_VALUE=$Value" }
  Invoke-Batch $Step $defines
}

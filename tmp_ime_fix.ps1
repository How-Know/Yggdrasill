$root = 'apps/yggdrasill/lib'
$targetImport = "import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';"
$changed = @()

Get-ChildItem -Path $root -Recurse -Filter *.dart | ForEach-Object {
    if ($_.Name -eq 'ime_aware_text_editing_controller.dart') {
        return
    }

    $content = Get-Content -Path $_.FullName -Raw -Encoding UTF8
    if ($content -notmatch 'TextEditingController\(') {
        return
    }

    $newContent = $content -replace 'TextEditingController\(', 'ImeAwareTextEditingController('
    if ($newContent -ne $content) {
        Set-Content -Path $_.FullName -Value $newContent -Encoding UTF8
        $changed += $_.FullName
    }
}

foreach ($file in $changed) {
    $content = Get-Content -Path $file -Raw -Encoding UTF8
    if ($content.Contains($targetImport)) {
        continue
    }

    $lines = $content -split "`n", 0, "SimpleMatch"
    $insertIndex = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Trim().StartsWith('import ')) {
            $insertIndex = $i + 1
        }
    }

    $list = New-Object System.Collections.Generic.List[string]
    $list.AddRange($lines)
    $list.Insert($insertIndex, $targetImport)
    $result = [string]::Join("`n", $list)
    Set-Content -Path $file -Value $result -Encoding UTF8
}

Write-Host "Updated $($changed.Count) files"


















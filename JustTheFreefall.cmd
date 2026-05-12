<# : batch portion
@echo off
cd /d "%~dp0"
:: Forward any drag-and-drop arguments to PowerShell
set "DROPPED_FILES="
:argloop
if "%~1"=="" goto :run
if defined DROPPED_FILES (set "DROPPED_FILES=%DROPPED_FILES%|%~1") else (set "DROPPED_FILES=%~1")
shift
goto :argloop
:run
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "$env:DROPPED_FILES = '%DROPPED_FILES%'; Invoke-Expression (Get-Content '%~f0' -Raw)"
pause
exit /b
#>

# --- GOPRO TRIMMER ---
# Drag files onto this script, or double-click to open a file picker.
# Place ffmpeg.exe in the same folder.

Add-Type -AssemblyName System.Windows.Forms

# --- SETTINGS (edit these) ---
$trimStart    = 10      # Seconds to skip from START
$keepDuration = 75      # Seconds to keep after trimStart
$suffix       = "_trim" # Appended to output filenames

# Output folder options:
#   $outputPicker = $true   -> pop up a folder picker each run
#   $outputPicker = $false  -> use $outputDefault automatically
#   $outputDefault = ""     -> save alongside the source files
#   $outputDefault = "C:\Videos\Trimmed"  -> save to a fixed folder
#   $outputDefault = "Trimmed"            -> relative to the script folder
$outputPicker  = $true
$outputDefault = ""
# -----------------------------

$scriptDir = $PWD.Path
$ffmpeg    = Join-Path $scriptDir "ffmpeg.exe"

if (-not (Test-Path $ffmpeg)) {
    Write-Host "Error: ffmpeg.exe must be in the same folder as this script." -ForegroundColor Red
    return
}

# --- Get files: drag-and-drop args or file picker ---
$files = @()

if ($env:DROPPED_FILES) {
    $files = $env:DROPPED_FILES -split '\|' | Where-Object { $_ -and (Test-Path $_) }
}

if ($files.Count -eq 0) {
    $dcim = Join-Path $scriptDir "DCIM"
    $startDir = $dcim
    if (Test-Path $dcim) {
        $goProDir = Get-ChildItem $dcim -Directory -Filter "*GOPRO" | Sort-Object Name | Select-Object -Last 1
        if ($goProDir) { $startDir = $goProDir.FullName }
    }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = "Select GoPro videos to trim"
    $dialog.Filter = "Video Files|*.mp4;*.MP4|All Files|*.*"
    if (Test-Path $startDir) { $dialog.InitialDirectory = $startDir }

    if ($dialog.ShowDialog() -ne "OK") {
        Write-Host "Cancelled." -ForegroundColor Gray
        return
    }
    $files = $dialog.FileNames
}

# --- Resolve output folder ---
$outDir = ""

# Resolve default path (could be relative to script dir)
$resolvedDefault = ""
if ($outputDefault) {
    if ([IO.Path]::IsPathRooted($outputDefault)) {
        $resolvedDefault = $outputDefault
    } else {
        $resolvedDefault = Join-Path $scriptDir $outputDefault
    }
}

if ($outputPicker) {
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Select output folder for trimmed files"
    $folderDialog.ShowNewFolderButton = $true
    $folderDialog.RootFolder = [Environment+SpecialFolder]::MyComputer
    if ($resolvedDefault -and (Test-Path $resolvedDefault)) {
        $folderDialog.SelectedPath = $resolvedDefault
    }
    if ($folderDialog.ShowDialog() -eq "OK") {
        $outDir = $folderDialog.SelectedPath
    } else {
        Write-Host "Cancelled." -ForegroundColor Gray
        return
    }
} elseif ($resolvedDefault) {
    $outDir = $resolvedDefault
}
# If $outDir is still empty, outputs go alongside source files (per-file below)

if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# --- Trim ---
Write-Host "`nTrimming $($files.Count) file(s): skip ${trimStart}s, keep ${keepDuration}s" -ForegroundColor White
if ($outDir) { Write-Host "Output:  $outDir" -ForegroundColor White }
Write-Host ""

$batchSw = [Diagnostics.Stopwatch]::StartNew()
$trimmed = 0
$skipped = 0
$failed  = 0

foreach ($filePath in $files) {
    $file    = Get-Item $filePath
    $destDir = if ($outDir) { $outDir } else { $file.DirectoryName }
    $output  = Join-Path $destDir "$($file.BaseName)${suffix}$($file.Extension)"

    Write-Host "  $($file.Name)" -NoNewline -ForegroundColor Cyan

    if (Test-Path $output) {
        Write-Host " -> skipped (output exists)" -ForegroundColor Yellow
        $skipped++
        continue
    }

    $args = @(
        "-n"
        "-v", "quiet"
        "-progress", "$env:TEMP\ffprog.txt"
        "-ss", $trimStart
        "-i", $filePath
        "-t", $keepDuration
        "-c", "copy"
        "-map", "0:v", "-map", "0:a"
        "-map_chapters", "-1"
        "-reset_timestamps", "1"
        "-avoid_negative_ts", "make_zero"
        $output
    )

    $targetUs = [long]$keepDuration * 1000000
    if (Test-Path "$env:TEMP\ffprog.txt") { Remove-Item "$env:TEMP\ffprog.txt" -Force }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $ffmpeg -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardError "$env:TEMP\fferr.txt"
    $barLen = 20

    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 250
        $elapsed = $sw.Elapsed.ToString("mm\:ss")
        if (Test-Path "$env:TEMP\ffprog.txt") {
            $tail = Get-Content "$env:TEMP\ffprog.txt" -Tail 15 -ErrorAction SilentlyContinue
            $lastUs = $tail | Select-String -Pattern '^out_time_us=(\d+)' | Select-Object -Last 1
            if ($lastUs) {
                $us = [long]$lastUs.Matches[0].Groups[1].Value
                $pct = [math]::Min(100, [int]($us * 100 / $targetUs))
                $filled = [math]::Floor($pct * $barLen / 100)
                $empty = $barLen - $filled
                $bar = ("$([char]0x2588)" * $filled) + ("$([char]0x2591)" * $empty)
                Write-Host "`r  $($file.Name) [$bar] $pct% $elapsed  " -NoNewline -ForegroundColor Cyan
            }
        }
    }
    $proc.WaitForExit()
    $sw.Stop()
    $elapsed = $sw.Elapsed.ToString("mm\:ss")

    if ($proc.ExitCode -eq 0) {
        $bar = "$([char]0x2588)" * $barLen
        Write-Host "`r  $($file.Name) [$bar] 100% $elapsed  " -NoNewline -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  -> $($file.BaseName)${suffix}$($file.Extension)" -ForegroundColor Green
        $trimmed++
    } else {
        $errMsg = ""
        if (Test-Path "$env:TEMP\fferr.txt") {
            $errMsg = (Get-Content "$env:TEMP\fferr.txt" -Tail 3 -ErrorAction SilentlyContinue) -join " "
        }
        Write-Host "`r  $($file.Name) -> FAILED (exit $($proc.ExitCode))                                  " -ForegroundColor Red
        if ($errMsg) { Write-Host "     $errMsg" -ForegroundColor DarkRed }
        if (Test-Path $output) { Remove-Item $output -Force -ErrorAction SilentlyContinue }
        $failed++
    }

    Remove-Item "$env:TEMP\ffprog.txt", "$env:TEMP\fferr.txt" -Force -ErrorAction SilentlyContinue
}

$batchSw.Stop()
$total = $batchSw.Elapsed.ToString("mm\:ss")
Write-Host ""
Write-Host "Done in $total - trimmed $trimmed, skipped $skipped, failed $failed`n" -ForegroundColor White

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

# --- JUST THE FREEFALL ---
# Drag MP4 files onto this script, or double-click to open a file picker.
# Place ffmpeg.exe in the same folder.

Add-Type -AssemblyName System.Windows.Forms

# --- SETTINGS (edit these) ---
$trimStart    = 10      # Seconds to skip from START
$keepDuration = 75      # Seconds to keep after trimStart
$suffix       = "_trim" # Appended to output filenames
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
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = "Select videos to trim"
    $dialog.Filter = "Video Files|*.mp4|All Files|*.*"

    if ($dialog.ShowDialog() -ne "OK") {
        Write-Host "Cancelled." -ForegroundColor Gray
        return
    }
    $files = $dialog.FileNames
}

# --- Output folder picker ---
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.Description = "Select output folder for trimmed files"
$folderDialog.ShowNewFolderButton = $true
$folderDialog.RootFolder = [Environment+SpecialFolder]::MyComputer

if ($folderDialog.ShowDialog() -ne "OK") {
    Write-Host "Cancelled." -ForegroundColor Gray
    return
}
$outDir = $folderDialog.SelectedPath

if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# --- Trim ---
Write-Host "`nTrimming $($files.Count) file(s): skip ${trimStart}s, keep ${keepDuration}s" -ForegroundColor White
Write-Host "Output:  $outDir" -ForegroundColor White
Write-Host ""

$batchSw = [Diagnostics.Stopwatch]::StartNew()
$trimmed = 0
$skipped = 0
$failed  = 0

foreach ($filePath in $files) {
    try {
        $file   = Get-Item $filePath
        $output = Join-Path $outDir "$($file.BaseName)${suffix}$($file.Extension)"

        Write-Host "  $($file.Name)" -NoNewline -ForegroundColor Cyan

        if (Test-Path $output) {
            Write-Host " -> skipped (output exists)" -ForegroundColor Yellow
            $skipped++
            continue
        }

        $ffArgs = @(
            "-n"
            "-v", "quiet"
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

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath $ffmpeg -ArgumentList $ffArgs -NoNewWindow -PassThru -RedirectStandardError "$env:TEMP\fferr.txt"
        $null = $proc.Handle  # Force handle cache so ExitCode survives after exit

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 250
            $elapsed = $sw.Elapsed.ToString("mm\:ss")
            Write-Host "`r  $($file.Name)  $elapsed" -NoNewline -ForegroundColor Cyan
        }
        $sw.Stop()
        $elapsed = $sw.Elapsed.ToString("mm\:ss")

        if ($proc.ExitCode -eq 0) {
            Write-Host "`r  $($file.Name)  $elapsed -> $($file.BaseName)${suffix}$($file.Extension)" -ForegroundColor Green
            $trimmed++
        } else {
            $errMsg = ""
            if (Test-Path "$env:TEMP\fferr.txt") {
                $errMsg = (Get-Content "$env:TEMP\fferr.txt" -Tail 3 -ErrorAction SilentlyContinue) -join " "
            }
            Write-Host "`r  $($file.Name)  $elapsed -> FAILED (exit $($proc.ExitCode))     " -ForegroundColor Red
            if ($errMsg) { Write-Host "     $errMsg" -ForegroundColor DarkRed }
            if (Test-Path $output) { Remove-Item $output -Force -ErrorAction SilentlyContinue }
            $failed++
        }

        Remove-Item "$env:TEMP\fferr.txt" -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "`r  $filePath -> ERROR: $($_.Exception.Message)     " -ForegroundColor Red
        $failed++
    }
}

$batchSw.Stop()
$total = $batchSw.Elapsed.ToString("mm\:ss")
Write-Host ""
Write-Host "Done in $total - trimmed $trimmed, skipped $skipped, failed $failed`n" -ForegroundColor White

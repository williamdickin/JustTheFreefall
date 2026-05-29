<# : batch portion
@echo off
cd /d "%~dp0"
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression (Get-Content '%~f0' -Raw)"
pause
exit /b
#>

# --- JUST THE FREEFALL ---
# Accelerometer-based freefall detection + lossless trim.
# Double-click to launch. Place ffmpeg.exe in the same folder.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- DETECTION CONSTANTS ---
$MAG_THRESH    = 14
$VAR_THRESH    = 45
$WINDOW_SEC    = 5.0
$EXIT_LOOKBACK = 75
$EXIT_RATE_DIP = -0.5
$EXIT_PAD      = 10
$END_PAD       = 2
$suffix        = "_trim"
# ---------------------------

$scriptDir = $PWD.Path
$ffmpeg    = Join-Path $scriptDir "ffmpeg.exe"

if (-not (Test-Path $ffmpeg)) {
    Write-Host "Error: ffmpeg.exe must be in the same folder as this script." -ForegroundColor Red
    return
}

# =====================================================================
# INLINE C# — FULL PIPELINE: ffmpeg + GPMF parse + signal processing
# =====================================================================
Add-Type -Language CSharp @"
using System;
using System.IO;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Collections.Generic;

public class SignalProcessor
{
    public struct AnalysisResult
    {
        public int ExitSec;
        public int DeploySec;
        public int DeployStart;
        public int DeployEnd;
        public double Duration;
        public bool HasTelemetry;
        public bool Found;
        public string Error;
        public string CreationTime;
    }

    // ---- Signal processing helpers ----
    static double[] RollingMean(double[] data, int halfWin)
    {
        int n = data.Length;
        double[] r = new double[n];
        double sum = 0;
        int right = Math.Min(halfWin, n - 1);
        for (int i = 0; i <= right; i++) sum += data[i];
        r[0] = sum / (right + 1);
        for (int i = 1; i < n; i++)
        {
            int ol = i - 1 - halfWin, nr = i + halfWin;
            if (ol >= 0) sum -= data[ol];
            if (nr < n) sum += data[nr];
            int lo = Math.Max(0, i - halfWin), hi = Math.Min(n - 1, i + halfWin);
            r[i] = sum / (hi - lo + 1);
        }
        return r;
    }

    static double[] RollingVariance(double[] data, int halfWin)
    {
        int n = data.Length;
        double[] r = new double[n];
        double sum = 0, sumSq = 0;
        int right = Math.Min(halfWin, n - 1);
        for (int i = 0; i <= right; i++) { sum += data[i]; sumSq += data[i] * data[i]; }
        int cnt = right + 1; double m = sum / cnt;
        r[0] = (sumSq / cnt) - (m * m);
        for (int i = 1; i < n; i++)
        {
            int ol = i - 1 - halfWin, nr = i + halfWin;
            if (ol >= 0) { sum -= data[ol]; sumSq -= data[ol] * data[ol]; }
            if (nr < n) { sum += data[nr]; sumSq += data[nr] * data[nr]; }
            int lo = Math.Max(0, i - halfWin), hi = Math.Min(n - 1, i + halfWin);
            cnt = hi - lo + 1; m = sum / cnt;
            r[i] = (sumSq / cnt) - (m * m);
        }
        return r;
    }

    static double[] Gradient(double[] data, double dt)
    {
        int n = data.Length;
        double[] r = new double[n];
        if (n < 2) return r;
        double dt2 = 2.0 * dt;
        r[0] = (data[1] - data[0]) / dt;
        for (int i = 1; i < n - 1; i++) r[i] = (data[i + 1] - data[i - 1]) / dt2;
        r[n - 1] = (data[n - 1] - data[n - 2]) / dt;
        return r;
    }

    // ---- GPMF binary parser ----
    static short ReadBE16(BinaryReader br)
    {
        byte[] b = br.ReadBytes(2);
        if (b.Length < 2) return 0;
        return (short)((b[0] << 8) | b[1]);
    }
    static ushort ReadBEU16(BinaryReader br)
    {
        byte[] b = br.ReadBytes(2);
        if (b.Length < 2) return 0;
        return (ushort)((b[0] << 8) | b[1]);
    }
    static int ReadBE32(BinaryReader br)
    {
        byte[] b = br.ReadBytes(4);
        if (b.Length < 4) return 0;
        return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    }

    static void ParseGPMF(string binPath, out double[] ax, out double[] ay, out double[] az)
    {
        var lx = new List<double>(); var ly = new List<double>(); var lz = new List<double>();
        using (var fs = File.OpenRead(binPath))
        using (var br = new BinaryReader(fs))
        {
            int scale = 100;
            while (br.BaseStream.Position < br.BaseStream.Length - 8)
            {
                byte[] kb = br.ReadBytes(4);
                if (kb.Length < 4) break;
                string key = System.Text.Encoding.ASCII.GetString(kb);
                int type = br.ReadByte();
                int structSize = br.ReadByte();
                ushort repeat = ReadBEU16(br);
                int dataSize = structSize * repeat;
                int padded = dataSize % 4 == 0 ? dataSize : dataSize + (4 - dataSize % 4);

                if (type == 0) { if (key == "STRM") scale = 100; continue; }
                long dataStart = br.BaseStream.Position;

                if (key == "SCAL")
                {
                    if (type == (int)'s' && dataSize >= 2)
                    { int v = (int)ReadBE16(br); scale = Math.Max(1, Math.Abs(v)); }
                    else if (type == (int)'l' && dataSize >= 4)
                    { int v = ReadBE32(br); scale = Math.Max(1, Math.Abs(v)); }
                    else if (type == (int)'S' && dataSize >= 2)
                    { ushort v = ReadBEU16(br); if (v > 0) scale = v; }
                }
                else if (key == "ACCL" && type == (int)'s' && structSize == 6)
                {
                    for (int s = 0; s < repeat; s++)
                    {
                        if (br.BaseStream.Position + 6 > br.BaseStream.Length) break;
                        double x = (double)ReadBE16(br) / scale;
                        double y = (double)ReadBE16(br) / scale;
                        double z = (double)ReadBE16(br) / scale;
                        lx.Add(x); ly.Add(y); lz.Add(z);
                    }
                }
                br.BaseStream.Position = dataStart + padded;
            }
        }
        ax = lx.ToArray(); ay = ly.ToArray(); az = lz.ToArray();
    }

    // ---- Run ffmpeg ----
    static string RunFFmpeg(string ffmpegPath, string args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = ffmpegPath, Arguments = args,
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true
        };
        using (var p = Process.Start(psi))
        {
            string stderr = p.StandardError.ReadToEnd();
            p.WaitForExit();
            return stderr;
        }
    }

    // ---- Full analysis pipeline ----
    public static AnalysisResult Analyze(string filePath, string ffmpegPath,
        double magThresh, double varThresh, double windowSec,
        double exitLookback, double exitRateDip)
    {
        var result = new AnalysisResult
        {
            ExitSec = -1, DeploySec = -1, DeployStart = -1, DeployEnd = -1,
            Duration = 0, HasTelemetry = false, Found = false, Error = null
        };

        try
        {
            // Probe
            string probeOut = RunFFmpeg(ffmpegPath, "-i \"" + filePath + "\"");
            int gpmfIdx = -1; double duration = 0;

            var mGpmf = Regex.Match(probeOut, @"Stream #0:(\d+)[^\n]*gpmd");
            if (mGpmf.Success) gpmfIdx = int.Parse(mGpmf.Groups[1].Value);

            var mDur = Regex.Match(probeOut, @"Duration:\s*(\d+):(\d+):([\d.]+)");
            if (mDur.Success)
                duration = int.Parse(mDur.Groups[1].Value) * 3600 +
                           int.Parse(mDur.Groups[2].Value) * 60 +
                           double.Parse(mDur.Groups[3].Value, System.Globalization.CultureInfo.InvariantCulture);

            var mTime = Regex.Match(probeOut, @"creation_time\s*:\s*(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})");
            if (mTime.Success)
                result.CreationTime = mTime.Groups[2].Value + "/" + mTime.Groups[3].Value + "/" +
                    mTime.Groups[1].Value + " " + mTime.Groups[4].Value + ":" + mTime.Groups[5].Value;

            result.Duration = duration;
            if (gpmfIdx < 0 || duration <= 0) return result;

            // Extract telemetry
            string binFile = Path.Combine(Path.GetTempPath(), "jtf_telemetry_" + Path.GetRandomFileName() + ".bin");
            RunFFmpeg(ffmpegPath, "-y -i \"" + filePath + "\" -map 0:" + gpmfIdx + " -f data \"" + binFile + "\"");

            if (!File.Exists(binFile) || new FileInfo(binFile).Length == 0)
            {
                try { File.Delete(binFile); } catch { }
                return result;
            }

            // Parse GPMF
            double[] ax, ay, az;
            ParseGPMF(binFile, out ax, out ay, out az);
            try { File.Delete(binFile); } catch { }

            if (ax.Length < 10) return result;
            result.HasTelemetry = true;

            // Signal processing
            int n = ax.Length;
            double dt = duration / n;
            int halfWin = Math.Max(1, (int)(windowSec / 2.0 / dt));

            double[] rawMag = new double[n];
            for (int i = 0; i < n; i++)
                rawMag[i] = Math.Sqrt(ax[i] * ax[i] + ay[i] * ay[i] + az[i] * az[i]);

            double[] rx = RollingMean(ax, halfWin);
            double[] ry = RollingMean(ay, halfWin);
            double[] rz = RollingMean(az, halfWin);
            double[] magOfMean = new double[n];
            for (int i = 0; i < n; i++)
                magOfMean[i] = Math.Sqrt(rx[i] * rx[i] + ry[i] * ry[i] + rz[i] * rz[i]);

            double[] meanOfMag = RollingMean(rawMag, halfWin);
            double[] rollVar = RollingVariance(rawMag, halfWin);
            double[] mmRate = RollingMean(Gradient(meanOfMag, dt), halfWin);
            double[] varRate = RollingMean(Gradient(rollVar, dt), halfWin);
            double[] varAccel = RollingMean(Gradient(varRate, dt), halfWin);

            double baseline = 0;
            for (int i = 0; i < n; i++) baseline += meanOfMag[i];
            baseline /= n;

            // DEPLOYMENT
            double[] magCopy = (double[])magOfMean.Clone();
            int deployIdx = -1;
            for (int p = 0; p < 5; p++)
            {
                int bestIdx = 0;
                for (int i = 1; i < n; i++) if (magCopy[i] > magCopy[bestIdx]) bestIdx = i;
                if (magCopy[bestIdx] < magThresh) break;
                int ps = Math.Max(0, bestIdx - (int)(5.0 / dt));
                double maxVar = 0;
                for (int i = ps; i < bestIdx; i++) if (rollVar[i] > maxVar) maxVar = rollVar[i];
                if (maxVar >= varThresh) { deployIdx = bestIdx; break; }
                int zl = Math.Max(0, bestIdx - (int)(10.0 / dt));
                int zh = Math.Min(n - 1, bestIdx + (int)(10.0 / dt));
                for (int i = zl; i <= zh; i++) magCopy[i] = 0;
            }
            if (deployIdx < 0) return result;
            result.DeploySec = (int)Math.Round(deployIdx * dt);
            result.Found = true;

            int vpIdx = deployIdx; double vpVal = rollVar[deployIdx];
            int vl = Math.Max(0, deployIdx - (int)(10.0 / dt));
            for (int i = vl; i <= deployIdx; i++)
                if (rollVar[i] > vpVal) { vpVal = rollVar[i]; vpIdx = i; }

            int dsIdx = vpIdx;
            for (int i = vpIdx - 1; i >= 1; i--)
                if (varAccel[i] >= 0 && varAccel[i + 1] < 0) { dsIdx = i; break; }
            int deIdx = Math.Min(n - 1, dsIdx + (int)(15.0 / dt));
            for (int i = vpIdx + 1; i < n - 1; i++)
                if (varAccel[i] >= 0 && varAccel[i - 1] < 0) { deIdx = i; break; }

            result.DeployStart = (int)Math.Round(dsIdx * dt);
            result.DeployEnd = (int)Math.Round(deIdx * dt);

            // EXIT
            int sf = Math.Max(0, dsIdx - (int)(exitLookback / dt));
            int rs = -1, rc = 0;
            int[] rss = new int[1000], res = new int[1000];
            for (int i = sf; i < dsIdx; i++)
            {
                if (mmRate[i] < 0) { if (rs < 0) rs = i; }
                else { if (rs >= 0 && rc < 1000) { rss[rc] = rs; res[rc] = i - 1; rc++; rs = -1; } }
            }
            if (rs >= 0 && rc < 1000) { rss[rc] = rs; res[rc] = dsIdx - 1; rc++; }

            int vc = 0; int[] vs = new int[1000], ve = new int[1000];
            for (int r = 0; r < rc; r++)
            {
                bool below = false;
                for (int i = rss[r]; i <= res[r]; i++)
                    if (meanOfMag[i] < baseline) { below = true; break; }
                if (below && vc < 1000) { vs[vc] = rss[r]; ve[vc] = res[r]; vc++; }
            }

            double ba = 0; int bri = -1;
            for (int r = 0; r < vc; r++)
            {
                double a = 0;
                for (int i = vs[r]; i <= ve[r]; i++) a += Math.Abs(mmRate[i]) * dt;
                if (a > ba) { ba = a; bri = r; }
            }
            if (bri >= 0)
            {
                int ei = vs[bri];
                for (int i = vs[bri]; i <= ve[bri]; i++)
                    if (mmRate[i] <= exitRateDip) { ei = i; break; }
                result.ExitSec = (int)Math.Round(ei * dt);
            }
        }
        catch (Exception ex) { result.Error = ex.Message; }
        return result;
    }
}
"@

# =====================================================================
# INLINE C# — MODERN FOLDER PICKER (IFileDialog COM)
# =====================================================================
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;

public static class FolderPicker
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogRCW { }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show([In] IntPtr parent);
        void SetFileTypes();   // not used
        void SetFileTypeIndex([In] uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise();
        void Unadvise();
        void SetOptions([In] uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([In, MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([In, MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([In, MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close([MarshalAs(UnmanagedType.Error)] int hr);
        void SetClientGuid();
        void ClearClientData();
        void SetFilter([MarshalAs(UnmanagedType.Interface)] IntPtr pFilter);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid bhid,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName([In] uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes([In] uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, [In] uint hint, out int piOrder);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string pszPath, IntPtr pbc,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

    private const uint FOS_PICKFOLDERS = 0x00000020;
    private const uint FOS_FORCEFILESYSTEM = 0x00000040;
    private const uint SIGDN_FILESYSPATH = 0x80058000;
    private static readonly Guid IID_IShellItem =
        new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");

    // Returns selected folder path, or null if cancelled.
    public static string Pick(string title, string initialDir)
    {
        IFileDialog dialog = null;
        try
        {
            dialog = (IFileDialog)(new FileOpenDialogRCW());
            uint opts;
            dialog.GetOptions(out opts);
            dialog.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
            if (!string.IsNullOrEmpty(title)) dialog.SetTitle(title);

            if (!string.IsNullOrEmpty(initialDir))
            {
                IShellItem startItem;
                int hr = SHCreateItemFromParsingName(initialDir, IntPtr.Zero, IID_IShellItem, out startItem);
                if (hr == 0 && startItem != null) dialog.SetFolder(startItem);
            }

            int result = dialog.Show(IntPtr.Zero);
            if (result != 0) return null; // cancelled (S_OK == 0)

            IShellItem item;
            dialog.GetResult(out item);
            string path;
            item.GetDisplayName(SIGDN_FILESYSPATH, out path);
            return path;
        }
        catch { return null; }
        finally { if (dialog != null) Marshal.ReleaseComObject(dialog); }
    }
}
'@

# =====================================================================
# STATE
# =====================================================================
$startDir = [System.IO.Path]::GetPathRoot($scriptDir)
$script:outDir = $null

# Growable parallel lists (one entry per added video)
$script:filePaths   = New-Object System.Collections.ArrayList
$script:fileSizes   = New-Object System.Collections.ArrayList
$script:results     = New-Object System.Collections.ArrayList
$script:checkboxes  = New-Object System.Collections.ArrayList
$script:vidInfoLabels = New-Object System.Collections.ArrayList
$script:infoLabels  = New-Object System.Collections.ArrayList
$script:startCombos = New-Object System.Collections.ArrayList
$script:endCombos   = New-Object System.Collections.ArrayList
$script:savingsLabels = New-Object System.Collections.ArrayList

# Column X positions (shared by header, rows, and apply-all)
$COL_CHK   = 12
$COL_NAME  = 38
$COL_INFO  = 210
$COL_DET   = 358
$COL_START = 538
$COL_END   = 743
$COL_SAVE  = 948
$rowHeight = 32

# =====================================================================
# BUILD FORM
# =====================================================================
$font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$boldFont = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = "JustTheFreefall"
$form.Size = New-Object System.Drawing.Size(1090, 500)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 300)
$form.StartPosition = "CenterScreen"
$form.Font = $font

# ---- Top toolbar: Add Videos + Output location ----
$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Height = 40; $toolbar.Dock = "Top"
$form.Controls.Add($toolbar)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "Add Videos..."
$btnAdd.Size = "110,28"; $btnAdd.Location = "10,6"
$btnAdd.Font = $boldFont
$toolbar.Controls.Add($btnAdd)

$btnOut = New-Object System.Windows.Forms.Button
$btnOut.Text = "Set Output Folder..."
$btnOut.Size = "150,28"; $btnOut.Location = "128,6"
$toolbar.Controls.Add($btnOut)

$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text = "Output: (not set)"
$lblOut.Location = "290,11"; $lblOut.Size = "760,20"
$lblOut.ForeColor = [System.Drawing.Color]::Gray
$lblOut.AutoEllipsis = $true
$toolbar.Controls.Add($lblOut)

# ---- Header row (Start/End headers ARE the apply-all dropdowns) ----
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Height = 32; $headerPanel.Dock = "Top"
$form.Controls.Add($headerPanel)
# Same-edge docking resolves in reverse z-order: the back-most docks
# outermost (top). Toolbar must stay outermost, so push the header in
# front of it -> header docks just below the toolbar.
$headerPanel.BringToFront()
$headerPanel.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
    Text = "Video"; Location = "$COL_NAME,7"; Size = "170,20"; Font = $boldFont }))
$headerPanel.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
    Text = "Info"; Location = "$COL_INFO,7"; Size = "145,20"; Font = $boldFont }))
$headerPanel.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
    Text = "Detection"; Location = "$COL_DET,7"; Size = "175,20"; Font = $boldFont }))

# Start-from header = apply-all dropdown
$cmbApplyStart = New-Object System.Windows.Forms.ComboBox
$cmbApplyStart.Size = "200,24"; $cmbApplyStart.Location = "$COL_START,4"
$cmbApplyStart.DropDownStyle = "DropDownList"; $cmbApplyStart.Font = $boldFont
$cmbApplyStart.Items.AddRange(@("Start from...", "Exit -10s", "Exit", "Video start"))
$cmbApplyStart.SelectedIndex = 0
$headerPanel.Controls.Add($cmbApplyStart)

# End-at header = apply-all dropdown
$cmbApplyEnd = New-Object System.Windows.Forms.ComboBox
$cmbApplyEnd.Size = "200,24"; $cmbApplyEnd.Location = "$COL_END,4"
$cmbApplyEnd.DropDownStyle = "DropDownList"; $cmbApplyEnd.Font = $boldFont
$cmbApplyEnd.Items.AddRange(@("End at...", "Deployment", "Deployment + 3m", "Video end"))
$cmbApplyEnd.SelectedIndex = 0
$headerPanel.Controls.Add($cmbApplyEnd)

$headerPanel.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
    Text = "Savings"; Location = "$COL_SAVE,7"; Size = "200,20"; Font = $boldFont }))

# ---- Bottom bar: status + total + Trim/Cancel ----
$bottomPanel = New-Object System.Windows.Forms.Panel
$bottomPanel.Dock = "Bottom"; $bottomPanel.Height = 45
$form.Controls.Add($bottomPanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Add videos to begin"
$statusLabel.Location = "15,12"; $statusLabel.Size = "250,22"
$statusLabel.ForeColor = [System.Drawing.Color]::Gray
$bottomPanel.Controls.Add($statusLabel)

$totalLabel = New-Object System.Windows.Forms.Label
$totalLabel.Text = ""
$totalLabel.Location = "270,12"; $totalLabel.Size = "450,22"
$bottomPanel.Controls.Add($totalLabel)

$btnTrim = New-Object System.Windows.Forms.Button
$btnTrim.Text = "Trim"; $btnTrim.Size = "90,32"; $btnTrim.Location = "860,6"
$btnTrim.Anchor = "Bottom,Right"; $btnTrim.Font = $boldFont; $btnTrim.Enabled = $false
$btnTrim.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.AcceptButton = $btnTrim
$bottomPanel.Controls.Add($btnTrim)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancel"; $btnCancel.Size = "90,32"; $btnCancel.Location = "960,6"
$btnCancel.Anchor = "Bottom,Right"
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.CancelButton = $btnCancel
$bottomPanel.Controls.Add($btnCancel)

# ---- Scrollable list panel (fills remaining space) ----
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"; $panel.AutoScroll = $true
$form.Controls.Add($panel)
$panel.BringToFront()

# =====================================================================
# RESOLVE TRIM BOUNDS
# =====================================================================
function Get-TrimBounds($idx) {
    $r = $script:results[$idx]
    if (-not $r) { return $null }
    $vidDur = if ($r.Duration -gt 0) { $r.Duration } else { 300 }

    $sel = $script:startCombos[$idx].SelectedItem
    if     ($sel -match "^Exit -")   { $ts = [math]::Max(0, $r.ExitSec - $EXIT_PAD) }
    elseif ($sel -match "^Exit \(")  { $ts = $r.ExitSec }
    else                             { $ts = 0 }

    $sel = $script:endCombos[$idx].SelectedItem
    if     ($sel -match "^Deployment \+ 3m") { $te = [math]::Min([int]$vidDur, $r.DeployStart + 180) }
    elseif ($sel -match "^Deployment")       { $te = $r.DeployStart }
    else                                     { $te = [int]$vidDur }

    return @{ Start = $ts; End = $te; Duration = $vidDur }
}

# =====================================================================
# UPDATE SAVINGS + TRIM BUTTON STATE
# =====================================================================
function Update-Savings {
    $totalTimeSaved = 0; $totalSizeSaved = 0; $totalOrigSize = 0; $checkedCount = 0
    $count = $script:filePaths.Count

    for ($i = 0; $i -lt $count; $i++) {
        $sl = $script:savingsLabels[$i]
        $r = $script:results[$i]
        if (-not $r -or -not $script:startCombos[$i].Enabled) { $sl.Text = ""; continue }

        $bounds = Get-TrimBounds $i
        if (-not $bounds -or $bounds.End -le $bounds.Start) { $sl.Text = ""; continue }

        $keepDur = $bounds.End - $bounds.Start
        $vidDur = $bounds.Duration
        $timeSaved = [math]::Max(0, $vidDur - $keepDur)
        $fileSize = $script:fileSizes[$i]
        $sizeSaved = if ($vidDur -gt 0) { [long]($fileSize * $timeSaved / $vidDur) } else { 0 }

        $tsStr = [TimeSpan]::FromSeconds([int]$timeSaved).ToString("m\:ss")
        $mbStr = [math]::Round($sizeSaved / 1MB, 0)
        $sl.Text = "-$tsStr / ~$($mbStr) MB"

        if ($script:checkboxes[$i].Checked) {
            $totalTimeSaved += $timeSaved; $totalSizeSaved += $sizeSaved
            $totalOrigSize += $fileSize; $checkedCount++
        }
    }

    if ($checkedCount -gt 0) {
        $tTs = [TimeSpan]::FromSeconds([int]$totalTimeSaved).ToString("h\:mm\:ss")
        $tMb = [math]::Round($totalSizeSaved / 1MB, 0)
        $oMb = [math]::Round($totalOrigSize / 1MB, 0)
        $script:totalLabel.Text = "Total: $checkedCount videos, save ~$($tMb) MB of $($oMb) MB ($tTs trimmed)"
    } else {
        $script:totalLabel.Text = ""
    }

    Update-TrimButton
}

function Update-TrimButton {
    # Enabled only if output set, at least one checked, and not mid-analysis
    $anyChecked = $false
    for ($i = 0; $i -lt $script:checkboxes.Count; $i++) {
        if ($script:checkboxes[$i].Checked) { $anyChecked = $true; break }
    }
    $btnTrim.Enabled = ($script:outDir -ne $null) -and $anyChecked -and (-not $script:analyzing)
}

# =====================================================================
# APPLY-ALL HANDLERS
# =====================================================================
$cmbApplyStart.Add_SelectedIndexChanged({
    $sel = $cmbApplyStart.SelectedItem
    if ($sel -eq "Start from...") { return }
    $prefix = switch ($sel) {
        "Exit -10s"    { "Exit -" }
        "Exit"         { "Exit (" }
        "Video start"  { "Video start" }
    }
    if ($prefix) {
        for ($i = 0; $i -lt $script:startCombos.Count; $i++) {
            $cs = $script:startCombos[$i]; if (-not $cs.Enabled) { continue }
            for ($j = 0; $j -lt $cs.Items.Count; $j++) {
                if ($cs.Items[$j].ToString().StartsWith($prefix)) { $cs.SelectedIndex = $j; break }
            }
        }
    }
    # Reset header back to placeholder so it reads as a column header / re-usable action
    $cmbApplyStart.SelectedIndex = 0
})

$cmbApplyEnd.Add_SelectedIndexChanged({
    $sel = $cmbApplyEnd.SelectedItem
    if ($sel -eq "End at...") { return }
    $prefix = switch ($sel) {
        "Deployment"       { "Deployment (" }
        "Deployment + 3m"  { "Deployment + 3m" }
        "Video end"        { "Video end" }
    }
    if ($prefix) {
        for ($i = 0; $i -lt $script:endCombos.Count; $i++) {
            $ce = $script:endCombos[$i]; if (-not $ce.Enabled) { continue }
            for ($j = 0; $j -lt $ce.Items.Count; $j++) {
                if ($ce.Items[$j].ToString().StartsWith($prefix)) { $ce.SelectedIndex = $j; break }
            }
        }
    }
    $cmbApplyEnd.SelectedIndex = 0
})

# =====================================================================
# ADD A ROW (creates controls for one video, returns its index)
# =====================================================================
function Add-Row($filePath) {
    $idx = $script:filePaths.Count
    $fileName = [System.IO.Path]::GetFileName($filePath)
    $y = $idx * $rowHeight

    [void]$script:filePaths.Add($filePath)
    [void]$script:fileSizes.Add((Get-Item $filePath).Length)
    [void]$script:results.Add($null)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location = New-Object System.Drawing.Point($COL_CHK, ($y + 6))
    $chk.Size = New-Object System.Drawing.Size(18, 18); $chk.Checked = $false
    $chk.Add_CheckedChanged({ Update-Savings })
    $panel.Controls.Add($chk); [void]$script:checkboxes.Add($chk)

    $nl = New-Object System.Windows.Forms.Label
    $nl.Text = if ($fileName.Length -gt 22) { $fileName.Substring(0, 19) + "..." } else { $fileName }
    $nl.Location = New-Object System.Drawing.Point($COL_NAME, ($y + 6)); $nl.Size = "170,20"
    $panel.Controls.Add($nl)

    $vi = New-Object System.Windows.Forms.Label
    $vi.Text = "..."
    $vi.Location = New-Object System.Drawing.Point($COL_INFO, ($y + 6)); $vi.Size = "145,20"
    $vi.ForeColor = [System.Drawing.Color]::Gray
    $panel.Controls.Add($vi); [void]$script:vidInfoLabels.Add($vi)

    $il = New-Object System.Windows.Forms.Label
    $il.Text = "Queued..."
    $il.Location = New-Object System.Drawing.Point($COL_DET, ($y + 6)); $il.Size = "175,20"
    $il.ForeColor = [System.Drawing.Color]::Gray
    $panel.Controls.Add($il); [void]$script:infoLabels.Add($il)

    $cs = New-Object System.Windows.Forms.ComboBox
    $cs.Location = New-Object System.Drawing.Point($COL_START, ($y + 3)); $cs.Size = "200,24"
    $cs.DropDownStyle = "DropDownList"; $cs.Enabled = $false
    $cs.Add_SelectedIndexChanged({ Update-Savings })
    $panel.Controls.Add($cs); [void]$script:startCombos.Add($cs)

    $ce = New-Object System.Windows.Forms.ComboBox
    $ce.Location = New-Object System.Drawing.Point($COL_END, ($y + 3)); $ce.Size = "200,24"
    $ce.DropDownStyle = "DropDownList"; $ce.Enabled = $false
    $ce.Add_SelectedIndexChanged({ Update-Savings })
    $panel.Controls.Add($ce); [void]$script:endCombos.Add($ce)

    $sl = New-Object System.Windows.Forms.Label
    $sl.Text = ""
    $sl.Location = New-Object System.Drawing.Point($COL_SAVE, ($y + 6)); $sl.Size = "200,20"
    $sl.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
    $panel.Controls.Add($sl); [void]$script:savingsLabels.Add($sl)

    return $idx
}

# =====================================================================
# POPULATE ROW (after analysis)
# =====================================================================
function Populate-Row($idx, $r) {
    $script:results[$idx] = $r
    $cs = $script:startCombos[$idx]; $ce = $script:endCombos[$idx]
    $il = $script:infoLabels[$idx]; $chk = $script:checkboxes[$idx]
    $vi = $script:vidInfoLabels[$idx]
    $vidDur = $r.Duration; if ($vidDur -le 0) { $vidDur = 300 }
    $vidEndTs = [TimeSpan]::FromSeconds([int]$vidDur).ToString("m\:ss")

    $infoText = $vidEndTs
    if ($r.CreationTime) { $infoText = "$($r.CreationTime)  $vidEndTs" }
    $vi.Text = $infoText

    if ($r.Found -and $r.ExitSec -ge 0) {
        $exitTs   = [TimeSpan]::FromSeconds($r.ExitSec).ToString("m\:ss")
        $deployTs = [TimeSpan]::FromSeconds($r.DeploySec).ToString("m\:ss")
        $ffDur    = $r.DeploySec - $r.ExitSec
        $il.Text = "Exit $exitTs  Deploy $deployTs  ($($ffDur)s)"
        $il.ForeColor = [System.Drawing.Color]::Green
        $chk.Checked = $true

        $exitPad = [math]::Max(0, $r.ExitSec - $EXIT_PAD)
        $cs.Items.Add("Exit -$($EXIT_PAD)s ($([TimeSpan]::FromSeconds($exitPad).ToString('m\:ss')))") | Out-Null
        $cs.Items.Add("Exit ($exitTs)") | Out-Null
        $cs.Items.Add("Video start (0:00)") | Out-Null
        $cs.SelectedIndex = 0; $cs.Enabled = $true

        if ($r.DeployStart -ge 0) {
            $ce.Items.Add("Deployment ($([TimeSpan]::FromSeconds($r.DeployStart).ToString('m\:ss')))") | Out-Null
            $d3m = [math]::Min([int]$vidDur, $r.DeployStart + 180)
            $ce.Items.Add("Deployment + 3m ($([TimeSpan]::FromSeconds($d3m).ToString('m\:ss')))") | Out-Null
        }
        $ce.Items.Add("Video end ($vidEndTs)") | Out-Null
        $ce.SelectedIndex = 0; $ce.Enabled = $true
    } elseif ($r.HasTelemetry) {
        $il.Text = "No freefall detected"
        $il.ForeColor = [System.Drawing.Color]::FromArgb(180, 150, 0)
        $cs.Items.Add("Video start (0:00)") | Out-Null
        $cs.SelectedIndex = 0; $cs.Enabled = $true
        $ce.Items.Add("Video end ($vidEndTs)") | Out-Null
        $ce.SelectedIndex = 0; $ce.Enabled = $true
    } else {
        $il.Text = if ($r.Error) { "Error" } else { "No telemetry" }
        $il.ForeColor = [System.Drawing.Color]::Gray
        $cs.Items.Add("Video start (0:00)") | Out-Null
        $cs.SelectedIndex = 0; $cs.Enabled = $true
        $ce.Items.Add("Video end ($vidEndTs)") | Out-Null
        $ce.SelectedIndex = 0; $ce.Enabled = $true
    }

    Update-Savings
}

# =====================================================================
# ANALYZE PENDING ROWS (Timer-driven, processes any with $null result)
# =====================================================================
$script:analyzing = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50

$timer.Add_Tick({
    # Find next unanalyzed row
    $next = -1
    for ($i = 0; $i -lt $script:filePaths.Count; $i++) {
        if ($null -eq $script:results[$i]) { $next = $i; break }
    }

    if ($next -lt 0) {
        $timer.Stop()
        $script:analyzing = $false
        $statusLabel.Text = "$($script:filePaths.Count) of $($script:filePaths.Count) analyzed"
        Update-TrimButton
        return
    }

    $script:analyzing = $true
    Update-TrimButton
    $statusLabel.Text = "Analyzing $($next + 1) of $($script:filePaths.Count)..."

    $fp = $script:filePaths[$next]
    $fn = [System.IO.Path]::GetFileName($fp)
    Write-Host "  $fn  " -NoNewline -ForegroundColor Cyan
    Write-Host "analyzing..." -NoNewline -ForegroundColor DarkGray

    $r = [SignalProcessor]::Analyze($fp, $ffmpeg, $MAG_THRESH, $VAR_THRESH, $WINDOW_SEC, $EXIT_LOOKBACK, $EXIT_RATE_DIP)

    if ($r.Found -and $r.ExitSec -ge 0) {
        Write-Host "`r  $fn  Exit: $([TimeSpan]::FromSeconds($r.ExitSec).ToString('m\:ss'))  Deploy: $([TimeSpan]::FromSeconds($r.DeploySec).ToString('m\:ss'))" -ForegroundColor Green
    } elseif ($r.Error) {
        Write-Host "`r  $fn  Error: $($r.Error)" -ForegroundColor Red
    } else {
        Write-Host "`r  $fn  analyzed" -ForegroundColor Yellow
    }

    Populate-Row $next $r
})

# =====================================================================
# ADD VIDEOS BUTTON
# =====================================================================
$btnAdd.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = "Step 1: Select GoPro videos to trim"
    $dialog.Filter = "Video Files|*.mp4|All Files|*.*"
    if ($script:startDir -and (Test-Path $script:startDir)) {
        $dialog.InitialDirectory = $script:startDir
    }
    if ($dialog.ShowDialog() -ne "OK") { return }

    # Append, skipping any already in the list
    $existing = @{}
    foreach ($p in $script:filePaths) { $existing[$p] = $true }

    $added = 0
    foreach ($f in $dialog.FileNames) {
        if ($existing.ContainsKey($f)) { continue }
        Add-Row $f | Out-Null
        $added++
    }

    if ($added -gt 0) {
        $statusLabel.Text = "Analyzing..."
        if (-not $timer.Enabled) { $timer.Start() }
        # Emphasis moves to the next step: setting the output folder
        # (only if it isn't already set).
        $btnAdd.Font = $font
        if (-not $script:outDir) { $btnOut.Font = $boldFont }
    }
})

# =====================================================================
# SET OUTPUT FOLDER BUTTON
# =====================================================================
$btnOut.Add_Click({
    $picked = [FolderPicker]::Pick("Step 2: Choose where to save trimmed videos", $script:startDir)
    if (-not $picked) { return }
    $script:outDir = $picked
    $lblOut.Text = "Output: $picked"
    $lblOut.ForeColor = [System.Drawing.Color]::Black
    $btnOut.Font = $font
    Update-TrimButton
})

# =====================================================================
# SHOW FORM
# =====================================================================
$formResult = $form.ShowDialog()
$timer.Stop()

if ($formResult -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "Cancelled." -ForegroundColor Gray
    return
}

# =====================================================================
# TRIM
# =====================================================================
$outDir = $script:outDir
Write-Host "`nTrimming to: $outDir`n" -ForegroundColor White

$batchSw = [Diagnostics.Stopwatch]::StartNew()
$trimmed = 0; $skipped = 0; $failed = 0

for ($idx = 0; $idx -lt $script:filePaths.Count; $idx++) {
    $filePath = $script:filePaths[$idx]
    $fileName = [System.IO.Path]::GetFileName($filePath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $ext      = [System.IO.Path]::GetExtension($filePath)
    $output   = Join-Path $outDir "$baseName$suffix$ext"

    if (-not $script:checkboxes[$idx].Checked) {
        Write-Host "  $fileName -> skipped" -ForegroundColor DarkGray
        $skipped++; continue
    }

    $bounds = Get-TrimBounds $idx
    if (-not $bounds -or $bounds.End -le $bounds.Start) {
        Write-Host "  $fileName -> invalid range" -ForegroundColor Red
        $failed++; continue
    }
    if (Test-Path $output) {
        Write-Host "  $fileName -> skipped (exists)" -ForegroundColor Yellow
        $skipped++; continue
    }

    $trimStart = $bounds.Start
    $trimEnd = $bounds.End
    # Pad the end so the keyframe past the requested end is included (lossless overshoot).
    $paddedEnd = [math]::Min([int]$bounds.Duration, $trimEnd + $END_PAD)
    $keepDuration = $paddedEnd - $trimStart

    Write-Host "  $fileName  $($trimStart)s to $($paddedEnd)s ($($keepDuration)s)" -NoNewline -ForegroundColor Cyan

    $errFile = Join-Path $env:TEMP "jtf_fferr_$($idx).txt"
    $ffArgs = @(
        "-n"; "-v"; "error"; "-ss"; $trimStart; "-i"; "`"$filePath`""
        "-t"; $keepDuration; "-c"; "copy"
        "-map"; "0:v"; "-map"; "0:a?"
        "-map_chapters"; "-1"; "-reset_timestamps"; "1"
        "-avoid_negative_ts"; "make_zero"; "`"$output`""
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $ffmpeg -ArgumentList $ffArgs -NoNewWindow -PassThru -RedirectStandardError $errFile
    $null = $proc.Handle
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        Write-Host "`r  $fileName  $($trimStart)s to $($paddedEnd)s ($($keepDuration)s)  $($sw.Elapsed.ToString('mm\:ss'))" -NoNewline -ForegroundColor Cyan
    }
    $sw.Stop()

    if ($proc.ExitCode -eq 0) {
        Write-Host "`r  $fileName  $($sw.Elapsed.ToString('mm\:ss')) -> $baseName$suffix$ext                " -ForegroundColor Green
        $trimmed++
    } else {
        $errMsg = if (Test-Path $errFile) { (Get-Content $errFile -Tail 3 -ErrorAction SilentlyContinue) -join " " } else { "" }
        Write-Host "`r  $fileName  FAILED (exit $($proc.ExitCode))                " -ForegroundColor Red
        if ($errMsg) { Write-Host "     $errMsg" -ForegroundColor DarkRed }
        if (Test-Path $output) { Remove-Item $output -Force -ErrorAction SilentlyContinue }
        $failed++
    }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}

$batchSw.Stop()
Write-Host "`nDone in $($batchSw.Elapsed.ToString('mm\:ss')) - trimmed $trimmed, skipped $skipped, failed $failed`n" -ForegroundColor White

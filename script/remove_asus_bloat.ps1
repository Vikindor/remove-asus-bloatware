# =========================================================
# remove_asus_bloat.ps1 v1.0
# Created by Vikindor (https://vikindor.github.io/)
# Clean ASUS software remnants (Armoury Crate, ASUS Update, Link, Aura/AAC, MyASUS, etc.)
# - Kill processes
# - Stop/disable/delete services
# - Remove scheduled tasks (SAFE filter: never touches \Microsoft\..., avoids 'AsUser' false-positives)
# - Delete ASUS folders (Program Files / ProgramData / AppData) with ACL fix
# - Clean ASUS registry keys and Run autostarts
# - Optional: Package Cache cleanup (ASUS-only)
# - Optional: Microsoft Store ASUS apps cleanup (UWP & provisioned)
# =========================================================

$ErrorActionPreference = 'Stop'

function Try-Run {
    param(
        [string]$Label,
        [ScriptBlock]$Action,
        [switch]$WarnOKIfMissing
    )
    try {
        & $Action
        Write-Host "OK: $Label" -ForegroundColor Green
    } catch {
        $msg = $_.Exception.Message
        if ($WarnOKIfMissing) {
            Write-Host "SKIP/INFO: $Label ($msg)" -ForegroundColor Yellow
        } else {
            Write-Host "ERROR: $Label ($msg)" -ForegroundColor Red
        }
    }
}
function Do-Run {
    param(
        [string]$Label,
        [ScriptBlock]$Action,
        [switch]$WarnOKIfMissing
    )    
        Try-Run -Label $Label -Action $Action -WarnOKIfMissing:$WarnOKIfMissing    
}

# [0] Warn if 32-bit PS on 64-bit OS
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and [Environment]::Is64BitOperatingSystem) {
  Write-Host "WARN: 32-bit PowerShell detected on 64-bit OS. Prefer a 64-bit host (PowerShell 7 x64 or Windows PowerShell x64)." -ForegroundColor Yellow
}

# ---------------------------------------------------------
Write-Host "[1/6] Kill ASUS-related processes..." -ForegroundColor Cyan
$procGlobs = @(
  'ArmouryCrate*','Armoury*','ArmourySocketServer*',
  'AsusUpdate*','ASUS*','MyASUS*','Aura*','Aac*','Link*'
)
$procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $n = $_.Name
  ($procGlobs | Where-Object { $n -like $_ }).Count -gt 0
}
if ($procs) {
  foreach ($p in $procs) {
    Do-Run "terminate process $($p.Name) (PID $($p.Id))" { Stop-Process -Id $p.Id -Force }
  }
} else {
  Write-Host "SKIP/INFO: no ASUS-like processes running" -ForegroundColor Yellow
}

# ---------------------------------------------------------
Write-Host "[2/6] Stop/disable/delete likely ASUS services..." -ForegroundColor Cyan
$svcNames = @(
  'ArmouryCrateService',
  'ArmouryCrateControlInterface',
  'ArmourySocketServer',
  'ASUSLinkNear','ASUSOptimization','AsusCertService',
  'AsusUpdateCheck','AsusUpdateService','AsusAppService',
  'AacAudioSvc','AacVGA','AacLSvc','AsusOSD','ASUSSystemAnalysis','ASUSSwitch'
)
foreach ($s in $svcNames) {
  $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
  if ($null -ne $svc) {
    Do-Run "stop service $s" { Stop-Service $s -Force } -WarnOKIfMissing
    Do-Run "disable service $s" { Set-Service $s -StartupType Disabled }
    Do-Run "delete service $s" { sc.exe delete "$s" | Out-Null }
  } else {
    Write-Host "SKIP/INFO: service not found $s" -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------
Write-Host "[3/6] Remove scheduled tasks (SAFE filter)..." -ForegroundColor Cyan

$neverTouchMicrosoft = '^(?i)\\Microsoft\\'
$asusPathRx = '(?i)\\(ASUS|ASUSTeK)\\'
$asusNameRx = '(?i)(Armoury|Crate|Aura|Aac(Audio|VGA|LSvc)?|MyASUS|Asus(Update|Cert|Link|OSD|Switch|Optimization))'

$allTasks = @()
try { $allTasks = Get-ScheduledTask -ErrorAction Stop } catch {
  Write-Host "ERROR: cannot enumerate scheduled tasks ($($_.Exception.Message))" -ForegroundColor Red
}

$targets = $allTasks | Where-Object {
  if ($_.TaskPath -match $neverTouchMicrosoft) { return $false }
  if ($_.TaskPath -match $asusPathRx)         { return $true  }
  return ($_.TaskName -match $asusNameRx)
}

if ($targets) {
  foreach ($t in $targets) {
    $exists = Get-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue
    if (-not $exists) {
      Write-Host "SKIP/INFO: task already gone $($t.TaskPath)$($t.TaskName)" -ForegroundColor Yellow
      continue
    }
    Do-Run "stop task $($t.TaskPath)$($t.TaskName)" { Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath } -WarnOKIfMissing
    Do-Run "delete task $($t.TaskPath)$($t.TaskName)" { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false }
  }
} else {
  Write-Host "SKIP/INFO: no ASUS-like scheduled tasks found (safe filter)" -ForegroundColor Yellow
}

# ---------------------------------------------------------
Write-Host "[4/6] Delete ASUS folders (Program Files / ProgramData / AppData)..." -ForegroundColor Cyan
$folders = @(
  "$env:ProgramFiles\ASUS",
  "$env:ProgramFiles\ASUSTeK",
  "${env:ProgramFiles(x86)}\ASUS",
  "${env:ProgramFiles(x86)}\ASUSTeK",
  "$env:ProgramData\ASUS",
  "$env:ProgramData\Armoury Crate",
  "$env:APPDATA\ASUS",
  "$env:LOCALAPPDATA\ASUS"
) | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique

if ($folders.Count -gt 0) {
  foreach ($path in $folders) {
    Do-Run "take ownership $path" { Start-Process -FilePath takeown.exe -ArgumentList @('/f',"`"$path`"","/r","/d","y") -Wait -NoNewWindow } -WarnOKIfMissing
    Do-Run "grant Administrators:F $path" { Start-Process -FilePath icacls.exe -ArgumentList @("`"$path`"","/grant","Administrators:F","/t","/c") -Wait -NoNewWindow }
    Do-Run "remove folder $path" { Remove-Item -LiteralPath $path -Recurse -Force }
  }
} else {
  Write-Host "SKIP/INFO: no ASUS folders found" -ForegroundColor Yellow
}

# ---------------------------------------------------------
Write-Host "[5/6] Clean ASUS registry keys and autostarts..." -ForegroundColor Cyan
$regKeys = @(
  'HKLM:\SOFTWARE\ASUS',
  'HKLM:\SOFTWARE\WOW6432Node\ASUS',
  'HKCU:\SOFTWARE\ASUS'
)
foreach ($rk in $regKeys) {
  if (Test-Path $rk) {
    Do-Run "delete $rk" { Remove-Item -Path $rk -Recurse -Force }
  } else {
    Write-Host "SKIP/INFO: registry key not found $rk" -ForegroundColor Yellow
  }
}

$runHives = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)
$rx = '(?i)(Armoury|Crate|Aura|Aac|MyASUS|Asus(Update|Cert|Link|OSD|Switch|Optimization))'
foreach ($h in $runHives) {
  if (Test-Path $h) {
    $props = Get-ItemProperty -Path $h -ErrorAction SilentlyContinue
    foreach ($prop in $props.PSObject.Properties) {
      $name = $prop.Name
      $val  = [string]$prop.Value
      if ($name -and $val -and ($val -match $rx)) {
        Do-Run "delete Run value '$name' in $h" { Remove-ItemProperty -Path $h -Name $name -Force }
      }
    }
  }
}

# ---------------------------------------------------------
Write-Host "[6/6] Base cleanup complete." -ForegroundColor Cyan

function Invoke-PackageCacheCleanup {
  Write-Host "`n[OPTION] Package Cache cleanup (ASUS-only)..." -ForegroundColor Cyan
  $cache = "$env:ProgramData\Package Cache"
  if (-not (Test-Path $cache)) {
    Write-Host "SKIP/INFO: Package Cache not found: $cache" -ForegroundColor Yellow
    return
  }
  $rx = '(?i)(ASUS|ASUSTeK)'
  $targets = @()

  Get-ChildItem -LiteralPath $cache -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $dir = $_.FullName
    $isAsus = ($_.Name -match $rx)
    if (-not $isAsus) {
      $files = Get-ChildItem -LiteralPath $dir -Recurse -File -Include *.msi,*.cab,*.exe -ErrorAction SilentlyContinue
      foreach ($f in $files) {
        if ($f.Name -match $rx) { $isAsus = $true; break }
        try {
          if ($f.Extension -in @('.exe','.dll')) {
            $company = $f.VersionInfo.CompanyName
            if ($company -and ($company -match $rx)) { $isAsus = $true; break }
          }
        } catch {}
      }
    }
    if ($isAsus) { $targets += $dir }
  }

  $targets = $targets | Sort-Object -Unique
  if (-not $targets -or $targets.Count -eq 0) {
    Write-Host "SKIP/INFO: no ASUS-related entries in Package Cache" -ForegroundColor Yellow
    return
  }

  foreach ($path in $targets) {
    Do-Run "remove Package Cache folder $path" { Remove-Item -LiteralPath $path -Recurse -Force }
  }
}

function Invoke-StoreAppsCleanup {
  Write-Host "`n[OPTION] Microsoft Store ASUS apps cleanup..." -ForegroundColor Cyan

  $pkgs = Get-AppxPackage -AllUsers | Where-Object {
    $_.Name -match '(?i)(ASUS|ASUSTeK)'
  }
  if ($pkgs) {
    foreach ($p in $pkgs) {
      Do-Run "remove AppX $($p.Name) ($($p.PackageFullName))" {
        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers } catch { Remove-AppxPackage -Package $p.PackageFullName }
      } -WarnOKIfMissing
    }
  } else {
    Write-Host "SKIP/INFO: no ASUS AppX packages found" -ForegroundColor Yellow
  }

  try {
    $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match '(?i)(ASUS|ASUSTeK)' }
    foreach ($pp in $prov) {
      Do-Run "remove provisioned package $($pp.DisplayName)" { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName | Out-Null }
    }
  } catch {
    Write-Host "SKIP/INFO: cannot query provisioned packages (requires admin/Win10+): $($_.Exception.Message)" -ForegroundColor Yellow
  }

  $lap = Join-Path $env:LOCALAPPDATA 'Packages'
  if (Test-Path $lap) {
    $asusDirs = Get-ChildItem -LiteralPath $lap -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)(ASUS|ASUSTeK)' }
    foreach ($d in $asusDirs) {
      Do-Run "remove Packages dir $($d.FullName)" { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    }
  }
}

Write-Host "`nDone. It is recommended that you restart your PC." -ForegroundColor Cyan
Write-Host "`Choose optional cleanup or press 0 to exit." -ForegroundColor Cyan

while ($true) {
  Write-Host "`n=== Optional cleanup ===" -ForegroundColor Cyan
  Write-Host "[1] Remove ASUS leftovers from Package Cache"
  Write-Host "[2] Remove ASUS apps from Microsoft Store (UWP & provisioned)"
  Write-Host "[0] Exit"
  $choice = Read-Host "Select option"
  switch ($choice) {
    '1' { Invoke-PackageCacheCleanup }
    '2' { Invoke-StoreAppsCleanup }
    '0' { return }
	''  { continue } # empty input: just reprint menu, without warning
    default { Write-Host "SKIP/INFO: unknown option '$choice'" -ForegroundColor Yellow }
  }
}

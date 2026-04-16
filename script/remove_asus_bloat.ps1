# =========================================================
# remove_asus_bloat.ps1 v1.0.5
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
$script:HadErrors = $false

function Test-IsMissingError {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = $ErrorRecord.Exception.Message
    $fullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
    $category = $ErrorRecord.CategoryInfo.Category

    if (
        $ErrorRecord.Exception -is [System.Management.Automation.ItemNotFoundException] -or
        $category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound -or
        $fullyQualifiedErrorId -match 'ItemNotFound|PathNotFound|ObjectNotFound|NoMatching|NotFound|Missing' -or
        $message -match '(?i)\b(not\s+found|cannot\s+find|does\s+not\s+exist|no\s+such)\b'
    ) {
        return $true
    }

    return $false
}

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
        if ($WarnOKIfMissing -and (Test-IsMissingError $_)) {
            Write-Host "SKIP/INFO: $Label ($msg)" -ForegroundColor Yellow
        } else {
            $script:HadErrors = $true
            Write-Host "ERROR: $Label ($msg)" -ForegroundColor Red
        }
    }
}

function Invoke-NativeCommandChecked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$FilePath exited with code $exitCode."
    }
}

# [0] Warn if 32-bit PS on 64-bit OS
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
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
    Try-Run "Terminate process $($p.Name) (PID $($p.Id))" { Stop-Process -Id $p.Id -Force }
  }
} else {
  Write-Host "SKIP/INFO: No ASUS-like processes running" -ForegroundColor Yellow
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
    Try-Run "Stop service $s" { Stop-Service $s -Force } -WarnOKIfMissing
    Try-Run "Disable service $s" { Set-Service $s -StartupType Disabled }
    Try-Run "Delete service $s" { Invoke-NativeCommandChecked -FilePath 'sc.exe' -Arguments @('delete', $s) }
  } else {
    Write-Host "SKIP/INFO: Service not found $s" -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------
Write-Host "[3/6] Remove scheduled tasks (SAFE filter)..." -ForegroundColor Cyan

$neverTouchMicrosoft = '^(?i)\\Microsoft\\'
$asusPathRx = '(?i)\\(ASUS|ASUSTeK)\\'
$asusNameRx = '(?i)(Armoury|Crate|Aura|Aac(Audio|VGA|LSvc)?|MyASUS|Asus(Update|Cert|Link|OSD|Switch|Optimization))'

$allTasks = @()
try { $allTasks = Get-ScheduledTask -ErrorAction Stop } catch {
  $script:HadErrors = $true
  Write-Host "ERROR: Enumerate scheduled tasks ($($_.Exception.Message))" -ForegroundColor Red
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
      Write-Host "SKIP/INFO: Task already gone $($t.TaskPath)$($t.TaskName)" -ForegroundColor Yellow
      continue
    }
    Try-Run "Stop task $($t.TaskPath)$($t.TaskName)" { Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath } -WarnOKIfMissing
    Try-Run "Delete task $($t.TaskPath)$($t.TaskName)" { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false }
  }
} else {
  Write-Host "SKIP/INFO: No ASUS-like scheduled tasks found (safe filter)" -ForegroundColor Yellow
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
    Try-Run "Take ownership $path" { Invoke-NativeCommandChecked -FilePath 'takeown.exe' -Arguments @('/f', $path, '/r', '/d', 'y') } -WarnOKIfMissing
    Try-Run "Grant Administrators:F $path" { Invoke-NativeCommandChecked -FilePath 'icacls.exe' -Arguments @($path, '/grant', 'Administrators:F', '/t', '/c') }
    Try-Run "Remove folder $path" { Remove-Item -LiteralPath $path -Recurse -Force }
  }
} else {
  Write-Host "SKIP/INFO: No ASUS folders found" -ForegroundColor Yellow
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
    Try-Run "Delete $rk" { Remove-Item -Path $rk -Recurse -Force }
  } else {
    Write-Host "SKIP/INFO: Registry key not found $rk" -ForegroundColor Yellow
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
        Try-Run "Delete Run value '$name' in $h" { Remove-ItemProperty -Path $h -Name $name -Force }
      }
    }
  }
}

# ---------------------------------------------------------
if ($script:HadErrors) {
  Write-Host "`nCompleted with errors. Review the messages above before assuming ASUS software was fully removed." -ForegroundColor Yellow
} else {
  Write-Host "`nBase cleanup completed successfully." -ForegroundColor Green
}

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
    Write-Host "SKIP/INFO: No ASUS-related entries in Package Cache" -ForegroundColor Yellow
    return
  }

  foreach ($path in $targets) {
    Try-Run "Remove Package Cache folder $path" { Remove-Item -LiteralPath $path -Recurse -Force }
  }
}

function Invoke-StoreAppsCleanup {
  Write-Host "`n[OPTION] Microsoft Store ASUS apps cleanup..." -ForegroundColor Cyan

  $pkgs = Get-AppxPackage -AllUsers | Where-Object {
    $_.Name -match '(?i)(ASUS|ASUSTeK)'
  }
  if ($pkgs) {
    foreach ($p in $pkgs) {
      Try-Run "Remove AppX $($p.Name) ($($p.PackageFullName))" {
        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers } catch { Remove-AppxPackage -Package $p.PackageFullName }
      } -WarnOKIfMissing
    }
  } else {
    Write-Host "SKIP/INFO: No ASUS AppX packages found" -ForegroundColor Yellow
  }

  try {
    $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match '(?i)(ASUS|ASUSTeK)' }
    foreach ($pp in $prov) {
      Try-Run "Remove provisioned package $($pp.DisplayName)" { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName | Out-Null }
    }
  } catch {
    $msg = $_.Exception.Message
    if (Test-IsMissingError $_) {
      Write-Host "SKIP/INFO: Query provisioned packages ($msg)" -ForegroundColor Yellow
    } else {
      $script:HadErrors = $true
      Write-Host "ERROR: Query provisioned packages ($msg)" -ForegroundColor Red
    }
  }

  $lap = Join-Path $env:LOCALAPPDATA 'Packages'
  if (Test-Path $lap) {
    $asusDirs = Get-ChildItem -LiteralPath $lap -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)(ASUS|ASUSTeK)' }
    foreach ($d in $asusDirs) {
      Try-Run "Remove Packages dir $($d.FullName)" { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    }
  }
}

function Exit-WithSummary {
  if ($script:HadErrors) {
    Write-Host "`nCompleted with errors. Review the messages above before assuming ASUS software was fully removed." -ForegroundColor Yellow
    exit 1
  }

  Write-Host "`nDone. ASUS cleanup completed successfully. It is recommended that you restart your PC." -ForegroundColor Green
  exit 0
}

Write-Host "`nOptional cleanup is available below." -ForegroundColor Cyan
Write-Host "Choose optional cleanup or press 0 to exit." -ForegroundColor Cyan

while ($true) {
  Write-Host "`n=== Optional cleanup ===" -ForegroundColor Cyan
  Write-Host "[1] Remove ASUS leftovers from Package Cache"
  Write-Host "[2] Remove ASUS apps from Microsoft Store (UWP & provisioned)"
  Write-Host "[0] Exit"
  $choice = Read-Host "Select option"
  switch ($choice) {
    '1' { Invoke-PackageCacheCleanup }
    '2' { Invoke-StoreAppsCleanup }
    '0' { Exit-WithSummary }
	''  { continue } # empty input: just reprint menu, without warning
    default { Write-Host "SKIP/INFO: Unknown option '$choice'" -ForegroundColor Yellow }
  }
}

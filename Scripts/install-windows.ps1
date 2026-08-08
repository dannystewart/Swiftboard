param(
    [switch] $Uninstall
)

$ErrorActionPreference = "Stop"

$taskName = "Swiftboard"
$installDirectory = Join-Path $env:LOCALAPPDATA "Swiftboard"
$executable = Join-Path $installDirectory "swiftboard.exe"

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-Process -Name "swiftboard" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item $executable -Force -ErrorAction SilentlyContinue
    if ((Test-Path $installDirectory) -and -not (Get-ChildItem $installDirectory -Force)) {
        Remove-Item $installDirectory -Force
    }
    Write-Host "Swiftboard uninstalled."
    exit 0
}

$repoDirectory = Split-Path -Parent $PSScriptRoot
Push-Location $repoDirectory
try {
    Write-Host "Building Swiftboard..."
    swift build -c release
    if ($LASTEXITCODE -ne 0) {
        throw "swift build failed with exit code $LASTEXITCODE"
    }
    $binDirectory = (swift build -c release --show-bin-path).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not locate the release binary."
    }
} finally {
    Pop-Location
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Get-Process -Name "swiftboard" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item (Join-Path $binDirectory "swiftboard.exe") $executable -Force

$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Swiftboard.lnk"
Remove-Item $startupShortcut -Force -ErrorAction SilentlyContinue

$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$escapedExecutable = [System.Security.SecurityElement]::Escape($executable)
$startBoundary = (Get-Date).AddMinutes(1).ToString("s")
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Keeps Swiftboard running in the current user's desktop session.</Description>
    <URI>\Swiftboard</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$sid</UserId>
    </LogonTrigger>
    <CalendarTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedExecutable</Command>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "Swiftboard installed and running. Log: $installDirectory\swiftboard.log"
Write-Host "Run this script with -Uninstall to remove it."

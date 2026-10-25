# Build board programs, then take the board's lease (C:\PMFBuild\board-leases\lease.ps1) for the board
# step alone: upload each built image as it is with PureMetalForge's own uploader (--radio-firmware: no
# compile inside the lease), read its USB serial output or run a tools/board.py script against it, give
# the lease back in a finally (BOARDS.md, Ron 2026-10-25: a lease holds a board only while it is used).
# Every read has a hard end: Seconds (no script) or ScriptSeconds (the script's deadline). Run it from
# Bash (powershell.exe -File tools/board.ps1 ...): a lease the PowerShell tool's sandbox makes or removes
# is not seen by the other sessions (side-session notes, 2026-10-23).
#   one job:   tools/board.ps1 -Source rp2040/Diagnostics/cpu_verify.picow -Output build/cpu_verify.uf2 -Seconds 80
#   several:   tools/board.ps1 -Jobs "src|out|seconds|script|scriptSeconds;src|out|..."  (script may be empty)
param(
  [string]$Source = '',
  [string]$Output = '',
  [int]$Seconds = 30,
  [string]$Port = 'COM7',
  [string]$Compiler = 'C:\Users\ajtaj\Desktop\Github\PureBasicCode\OpenGl Work\ArduinoBasic\PureMetalForge.exe',
  [string]$Script = '',          # a tools/board.py script run against the board after the upload
  [int]$ScriptSeconds = 60,
  [string]$Jobs = '',
  [switch]$CompileOnly,          # build and check the image's end, no board
  [switch]$Speaker               # also hold the SPEAKER lease (a job that plays to the Bluetooth speaker)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# PureMetalForge.exe is a windowed program: Start-Process -Wait is what waits for it and gives its exit code
function Invoke-Pmf([string]$arguments, [string]$stdout) {
  $p = Start-Process -FilePath $Compiler -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru `
       -RedirectStandardOutput $stdout -RedirectStandardError "$stdout.err"
  return $p.ExitCode
}
$list = @()
if ($Jobs) {
  foreach ($j in $Jobs.Split(';')) {
    $f = $j.Split('|')
    $list += [pscustomobject]@{ Source = $f[0]; Output = $f[1]; Seconds = [int]$f[2]; Script = $f[3]; ScriptSeconds = [int]$f[4] }
  }
} else {
  $list += [pscustomobject]@{ Source = $Source; Output = $Output; Seconds = $Seconds; Script = $Script; ScriptSeconds = $ScriptSeconds }
}
# compile everything first, without the board, so a compile error never holds the lease
foreach ($job in $list) {
  $job | Add-Member src ([IO.Path]::GetFullPath((Join-Path $root $job.Source)))
  $job | Add-Member out ([IO.Path]::GetFullPath((Join-Path $root $job.Output)))
  [IO.Directory]::CreateDirectory((Split-Path $job.out -Parent)) | Out-Null
  $rc = Invoke-Pmf ('--compile "' + $job.src + '" -S -o "' + $job.out + '"') "$($job.out).build.log"
  if ($rc -ne 0) { Get-Content "$($job.out).build.log" | Select-Object -Last 20; throw "compile failed: $($job.out).build.log" }
  # the image must end below flash $40000: Ms. Pac-Man's pack is at $40000, the NES store at $50000
  $uf2 = [IO.File]::ReadAllBytes($job.out); $end = 0
  for ($o = 0; $o -lt $uf2.Length; $o += 512) {
    $e = [BitConverter]::ToUInt32($uf2, $o + 12) + [BitConverter]::ToUInt32($uf2, $o + 16)
    if ($e -gt $end) { $end = $e }
  }
  if ($end -gt 0x10040000) { throw ('{0}: image ends at 0x{1:X8}, past 0x10040000 (other programs keep data there): not uploaded' -f $job.Source, $end) }
  Write-Output ("{0}: image ends at 0x{1:X8}" -f $job.Source, $end)
  Get-Content "$($job.out).build.log" | Select-String 'SRAM left|ROM_TOTAL|rror' | ForEach-Object { $_.Line }
}
if ($CompileOnly) { exit 0 }
. C:\PMFBuild\board-leases\lease.ps1
# the lease's length: each job's upload (about 30 s) and its read, plus a minute
$minutes = 1 + ($list | ForEach-Object { 30 + $(if ($_.Script) { $_.ScriptSeconds } else { $_.Seconds }) } | Measure-Object -Sum).Sum / 60
$l = Get-BoardLease -Port $Port -Owner 'apple2c' -Minutes ([int][Math]::Ceiling($minutes))
$speakerLease = $null
$worst = 0
try {
  # the Bluetooth speaker pairs with one board at a time: it has its own lease
  if ($Speaker) { $speakerLease = Get-BoardLease -Port SPEAKER -Owner 'apple2c' -Minutes ([int][Math]::Ceiling($minutes)) }
  foreach ($job in $list) {
    Write-Output "==== $($job.Source) ($(Get-Date -Format HH:mm:ss))"
    $log = "$($job.out).board.log"
    $rc = Invoke-Pmf ('--compile --radio-firmware "' + $job.out + '" --port ' + $Port) $log
    Get-Content $log | Where-Object { $_ -notmatch '^\[DEBUG\]|TELEMETRY|_RP20|_RP23' } | Select-Object -Last 8
    if ($rc -eq 0) {
      Push-Location $root
      try {
        if ($job.Script) {
          $scriptPath = [IO.Path]::GetFullPath((Join-Path $root $job.Script))
          & py -3 tools/board.py --port $Port --seconds $job.ScriptSeconds --script $scriptPath --output "$($job.out).script.log"
        } else {
          & py -3 tools/board.py --port $Port --seconds $job.Seconds --output "$($job.out).serial.log"
        }
        $rc = $LASTEXITCODE
      } finally { Pop-Location }
    }
    if ($rc -ne 0) { $worst = $rc; Write-Output "==== $($job.Source): exit $rc" }
  }
} finally {
  if ($speakerLease) { Release-BoardLease $speakerLease }
  Release-BoardLease $l
  # a lease of ours must never outlive this script (one SPEAKER lease did on 2026-10-24, reason unknown)
  foreach ($held in @($speakerLease, $l)) {
    if ($held -and [IO.File]::Exists($held.Path)) {
      $text = $null; try { $text = [IO.File]::ReadAllText($held.Path) } catch {}
      if ($text -eq $held.Tag) { Remove-BoardLeaseFile $held.Path; Write-Output "LEASE $($held.Path) was still ours after release: removed" }
    }
  }
}
exit $worst

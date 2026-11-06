[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory.' }
if (-not ('SeedVcDirectory' -as [type])) { Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SeedVcDirectory {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern bool CreateDirectory(string path, IntPtr security);
  public static void CreateNew(string path) {
    if (!CreateDirectory(path, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
  }
}
"@
}
function New-ExclusiveDirectory([string]$Path) {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
  [SeedVcDirectory]::CreateNew($Path)
}
$parent = [IO.Path]::GetDirectoryName($OutputDirectory)
[IO.Directory]::CreateDirectory($parent) | Out-Null
$workspace = Join-Path $parent ('.speech-' + [Guid]::NewGuid().ToString('N'))
New-ExclusiveDirectory $workspace
try {
  Add-Type -AssemblyName System.Speech
  $speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
  try {
  $voices = @($speaker.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'en-*' })
  if ($voices.Count -eq 0) { throw 'An installed English Windows SAPI voice is required.' }
  $format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(22050, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
  $entries = @(
    @{ name='source.wav'; voice=$voices[0].VoiceInfo.Name; text='This is a local voice conversion test. The audio is generated for this example.' },
    @{ name='reference.wav'; voice=$voices[-1].VoiceInfo.Name; text='This reference is synthetic speech. We compare model settings using a neutral example.' }
  )
  foreach ($entry in $entries) {
    $scratch = Join-Path $workspace ('.item-' + [Guid]::NewGuid().ToString('N'))
    New-ExclusiveDirectory $scratch
    $staged = Join-Path $scratch $entry.name
    $destination = Join-Path $workspace $entry.name
    try {
      $speaker.SelectVoice($entry.voice)
      $speaker.SetOutputToWaveFile($staged, $format)
      $speaker.Speak($entry.text)
      $speaker.SetOutputToNull()
      [IO.File]::Move($staged, $destination)
      [IO.Directory]::Delete($scratch)
    } finally { $speaker.SetOutputToNull() }
  }
  } finally { $speaker.Dispose() }
  [IO.Directory]::Move($workspace, $OutputDirectory)
} catch {
  throw "Speech generation failed; staging files retained at $workspace`: $_"
}

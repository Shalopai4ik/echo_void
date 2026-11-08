# Records the trailer with Godot's Movie Maker at 1080p and encodes the MP4.
# Usage: tools\trailer\make_trailer.ps1 -Godot <godot.exe> -Ffmpeg <ffmpeg.exe>
param([Parameter(Mandatory)][string]$Godot, [Parameter(Mandatory)][string]$Ffmpeg)
$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $proj
New-Item -ItemType Directory -Force build/trailer | Out-Null
$backup = Get-Content project.godot -Raw
# the project pins a 960x540 window; the recording needs a 1080p one
($backup -replace 'window_width_override=960','window_width_override=1920' -replace 'window_height_override=540','window_height_override=1080') | Set-Content project.godot -NoNewline -Encoding utf8
try {
    & $Godot --path . --write-movie build/trailer/trailer.avi --fixed-fps 30 --script tools/trailer/trailer.gd | Out-Host
} finally {
    $backup | Set-Content project.godot -NoNewline -Encoding utf8
}
& $Ffmpeg -y -i build/trailer/trailer.avi -vf "fade=t=out:st=60.2:d=1.4" `
    -af "afade=t=in:d=0.8,afade=t=out:st=59.5:d=2.2,loudnorm=I=-16:TP=-1.5:LRA=11" `
    -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 `
    -movflags +faststart build/trailer/echo_of_void_trailer.mp4
Remove-Item build/trailer/trailer.avi

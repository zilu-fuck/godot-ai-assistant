$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$godot = "godot"

Write-Host "Running v2.2 runtime validation..."
& $godot --headless --path $projectRoot --script "res://test/v22_validation.gd"

Write-Host "Running v2.2 UI validation..."
& $godot --headless --path $projectRoot --editor --script "res://test/ui_validation.gd"

Write-Host "Running plugin load validation..."
& $godot --headless --path $projectRoot --editor --quit-after 1

Write-Host "v2.2 validations finished."

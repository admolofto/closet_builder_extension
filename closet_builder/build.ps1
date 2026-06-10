# Builds closet_builder.rbz from the repo (run from the repo root)
$out = "closet_builder.rbz"
if (Test-Path $out) { Remove-Item $out }
Compress-Archive -Path closet_builder.rb, closet_builder -DestinationPath "$out.zip"
Rename-Item "$out.zip" $out
Write-Host "Built $out"
